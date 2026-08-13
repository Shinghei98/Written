-- 0126 — the other half of a match profile stops being a free read.
--
-- **`0123` closed the gated half and left the ungated one open.**
-- `match_profile` returns school and bio and now refuses a blocked pair — but
-- the name, age, district and photographs on that same page come from a direct
-- read of `discovery_cards`, whose policy is *any signed-in user may read this
-- table*. So blocking somebody hid two fields and left their face.
--
-- In practice the page is reached from an admirer row or a chat banner, and
-- blocking revokes the first and freezes the second. That is exactly the
-- "a courtesy is not a rule" argument the discovery RPC exists to answer: what
-- protects the data is the policy, not which buttons a well-behaved client
-- draws.
--
-- **Deliberately not gated on `discovery_profile_reads`.** The Phase 4 flag
-- decides whether the *feed* is server-owned, and it is off; this is an
-- authorisation hole that exists today, so making it wait for a rollout would
-- mean choosing to leave it open. `match_profile` is ungated for the same
-- reason and has always been.
--
-- **One authorisation, called twice, rather than two copies.** `0122` and
-- `0123` each edited `match_profile`'s condition; a second function repeating
-- it would be a third place to edit and the first to be forgotten. This
-- factors it out and rewrites `match_profile` to call it, so the two pages of
-- one profile cannot disagree about who may see it.

begin;

create or replace function private.may_see_match(p_me uuid, p_target uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    p_me is not null
    and p_target is not null
    and p_me <> p_target
    -- A block ends every route, including the frozen conversation that `0122`
    -- otherwise treats as sufficient.
    and not private.is_blocked(p_me, p_target)
    and (
      exists (
        select 1 from public.likes l
         where l.liker_id = p_target and l.liked_id = p_me
           -- An invitation authorises while open or accepted; a declined one
           -- is history. `0122`.
           and l.status in ('pending', 'accepted')
      )
      or exists (
        select 1 from public.conversations c
         where (c.user_a = p_me and c.user_b = p_target)
            or (c.user_a = p_target and c.user_b = p_me)
      )
    );
$$;

comment on function private.may_see_match(uuid, uuid) is
  'Whether p_me may see p_target''s match profile: not blocked, and holding '
  'either an open/accepted invitation FROM them or a conversation with them. '
  'The single condition behind both match_profile and match_card, so the two '
  'halves of one page cannot disagree.';

revoke all on function private.may_see_match(uuid, uuid) from public, anon, authenticated;

create or replace function public.match_profile(target uuid)
returns table(school text, bio text)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    me uuid := auth.uid();
begin
    if not private.may_see_match(me, target) then
        -- **Nothing, rather than an error.** A refusal that says "no such
        -- relationship" tells a caller whether an account exists, which is a
        -- question they have no business asking. Zero rows is the same answer
        -- as a match who filled in neither field, and as a declined invitation.
        return;
    end if;

    return query
    with latest as (
        select distinct on (d.data_type) d.data_type, d.name
          from public.distilled_records d
         where d.user_id = target
           and d.source = 'user'
           and d.data_type in ('education', 'bio')
           and d.removed_at is null
         order by d.data_type, d.distilled_at desc
    )
    select (select name from latest where data_type = 'education'),
           (select name from latest where data_type = 'bio');
end;
$function$;

-- The card half, under the same condition. Returns the columns
-- `MatchProfileService` reads today, so routing it is a swap rather than a
-- redesign — the same judgement `0120` made about the feed.
create or replace function public.match_card(target uuid)
returns table (
  user_id uuid,
  display_name text,
  age integer,
  district text,
  photo_seeds integer[],
  photo_paths text[],
  interests jsonb,
  domains jsonb,
  top_subjects jsonb
)
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  me uuid := (select auth.uid());
begin
  if not private.may_see_match(me, target) then
    return;
  end if;

  return query
  select c.user_id, c.display_name, c.age, c.district, c.photo_seeds,
         c.photo_paths, c.interests, c.domains, c.top_subjects
    from public.discovery_cards c
   where c.user_id = target;
end;
$$;

comment on function public.match_card(uuid) is
  'The unguarded half of a match profile, guarded. Same condition as '
  'match_profile via private.may_see_match. Zero rows for a refusal and for '
  'somebody with no card, deliberately indistinguishable.';

-- **From `anon` by name, not only from `PUBLIC`.** Supabase''s default
-- privileges grant execute on every new `public` function to `anon` and
-- `authenticated`, so revoking from the pseudo-role leaves a direct grant in
-- place — the defect `0124`''s assertion caught before it applied.
revoke all on function public.match_card(uuid) from public, anon;
grant execute on function public.match_card(uuid) to authenticated;

do $$
declare
  a constant uuid := 'eb769605-5e2c-4175-8b9d-e3864ceaafb1';
  b constant uuid := '076f08f9-b27d-4004-bd5c-ec103c3496b0';
begin
  if has_function_privilege('anon', 'public.match_card(uuid)', 'execute') then
    raise exception 'anon may read a match card';
  end if;
  if has_function_privilege('authenticated', 'private.may_see_match(uuid,uuid)', 'execute') then
    raise exception 'a client may call the authorisation directly';
  end if;

  -- **The condition must discriminate on real rows.** The only like in this
  -- database is declined, so neither direction may see the other — and if this
  -- ever answers true, `0122` has regressed and the card would follow it.
  if private.may_see_match(a, b) or private.may_see_match(b, a) then
    raise exception 'a declined invitation still authorises a match profile';
  end if;
  if private.may_see_match(a, a) then
    raise exception 'may_see_match authorises somebody to themselves';
  end if;
  if private.may_see_match(null, b) then
    raise exception 'may_see_match authorises a null viewer';
  end if;
end
$$;

commit;
