-- The dynamic profile: how one match presents themselves to another.
--
-- Two things, split by how identifying they are.
--
-- **`discovery_cards.domains`** is the ontology mix — `[{domain, share}]`,
-- Music 0.46, Sport 0.31 — and goes on the card because it has to be computed
-- in Swift (`Ontology.mix` is where the term table lives) and because a coarse
-- share is the same class of thing the card already carries. A domain name
-- reveals less than the artist names already sitting beside it.
--
-- **`match_profile()`** is the school and the bio, which are not. Those stay
-- out of every general read path and come back only to somebody who has an
-- invitation from you or a conversation with you — which is exactly the two
-- places the app opens this page from. **The access rule is enforced here
-- rather than drawn in the UI**: a screen reachable from only two buttons is a
-- drawing, and this project has the habit of finding out that a guard which
-- silently does nothing is the shape of most of its bugs.

alter table public.discovery_cards
    add column if not exists domains jsonb not null default '[]'::jsonb;

comment on column public.discovery_cards.domains is
    'Ontology mix as [{"domain":"music","share":0.46}], ranked, computed on the '
    'device by Ontology.mix. Shares are over placed items and sum to 1 across '
    'all domains, so the top three usually will not.';

-- ---------------------------------------------------------------------------
-- The gated half
-- ---------------------------------------------------------------------------
--
-- `security definer` so it can read `distilled_records` for somebody who is not
-- the caller — `0001`'s policy is `auth.uid() = user_id`, so nothing else can.
-- The predicate below is the whole authorisation, and it is deliberately narrow:
--
--   * a like **they** sent **you**, which is the invitation screen; and
--   * a conversation containing both of you, which is the chatroom.
--
-- Not a like *you* sent *them*. Liking somebody is not being introduced to
-- them, and the app offers no route to this page from the feed.
--
-- Reads the base table rather than `summary_distilled_records`: that view is
-- `security_invoker = on`, so a definer function reading it is still filtered
-- to the caller's own rows and would return nothing for the target while
-- reporting no error at all. Same trap as `0036`.

create or replace function public.match_profile(target uuid)
returns table (school text, bio text)
language plpgsql
security definer
set search_path = public
as $$
declare
    me uuid := auth.uid();
begin
    if me is null or target is null or me = target then
        return;
    end if;

    if not exists (
        select 1 from public.likes l
         where l.liker_id = target and l.liked_id = me
    ) and not exists (
        select 1 from public.conversations c
         where (c.user_a = me and c.user_b = target)
            or (c.user_a = target and c.user_b = me)
    ) then
        -- **Nothing, rather than an error.** A refusal that says "no such
        -- relationship" tells a caller whether an account exists, which is a
        -- question they have no business asking. Zero rows is the same answer
        -- as a match who filled in neither field.
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
$$;

comment on function public.match_profile is
    'School and bio for somebody who has invited you or is talking to you. '
    'Returns no rows for anybody else — the two entry points as a predicate.';

-- `authenticated` only. `anon` has no `auth.uid()`, so the function would
-- refuse anyway, but a function an unauthenticated caller cannot invoke at all
-- is one fewer thing depending on that reasoning holding.
revoke all on function public.match_profile(uuid) from public, anon;
grant execute on function public.match_profile(uuid) to authenticated;
