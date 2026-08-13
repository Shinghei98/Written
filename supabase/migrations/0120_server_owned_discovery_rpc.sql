-- 0120 — the feed becomes a question asked of the server, not a table read.
--
-- **Today the client is handed the box and asked to be polite.** `0007`'s
-- policy is *any signed-in user may read `discovery_cards`*, and every rule
-- about who sees whom lives in Swift: `DiscoveryService` appends
-- `user_id=neq.<me>`, and `DiscoveryModel` filters liked people in three places
-- that have to agree. A courtesy is not a rule — another client against the
-- same anon key sees everybody — and three places that must agree are three
-- chances to disagree, which CLAUDE.md already records costing a bug.
--
-- This is Phase 4's first artifact: one function, `security definer`, that
-- takes **no parameter for whose feed it is**. That comes from `auth.uid()`,
-- for the reason `0061` gives about consent — a function that let a caller name
-- whose feed it was would be a function for reading somebody else's.
--
-- **It ships dark.** `assert_surface_allowed('matching')` requires
-- `discovery_profile_reads`, which is `false`, so every call refuses today.
-- `0103` proved that gate genuinely moves. Nothing in Swift calls this yet.
--
-- **Three things it deliberately does not do**, so the gaps are named rather
-- than discovered:
--
--   * **Blocking is a stub.** `private.is_blocked` answers false because the
--     product has no blocking feature and no table — §10 requires mutual-block
--     enforcement and it cannot be written against nothing. It is a named
--     function so blocking fills one body rather than being retrofitted through
--     call sites. **This is not a regression**: there is no blocking today
--     either, so this is strictly better than the status quo.
--   * **No rate limit.** §10 asks for one; it needs a counter table and a
--     decision about the window, which is its own migration.
--   * **No semantic matching.** It returns what `discovery_cards` already
--     holds, in a stable order, so the switch is a swap rather than a redesign
--     — a feed bug and a parsing bug look identical otherwise. Assertion-based
--     ranking arrives when `dyad_alignment_pairs` has a producer, which it does
--     not (0 rows).
--
-- **What it does do that today does not: eligibility.** Measured on production
-- before writing this — 2 users, both `sex = 'Male'`, both
-- `interested_in = {female}` — so the current feed shows each of them somebody
-- neither asked to see. Under this function they correctly see nobody.
-- **Expect an empty feed on the test accounts; that is the fix, not a fault.**

begin;

-- **Two columns describe gender in two vocabularies, and `lower()` is not the
-- bridge between them.**
--
--   `users.sex`           `Identity.columnValue` -> `Gender.label`
--                         'Male', 'Female', 'Non-binary'  (pipe-joined)
--   `users.interested_in` `Gender.rawValue`
--                         'male', 'female', 'nonbinary'   (text[])
--
-- `lower('Non-binary')` is `non-binary`, and the rawValue is `nonbinary`. So a
-- casefold comparison matches two of the three cases and **silently drops every
-- non-binary person from every feed in both directions** — the failure landing
-- hardest on the people it is least acceptable to drop quietly, which is the
-- same shape as `pushDemographics` overwriting a chosen gender.
--
-- One function so the mapping cannot drift, the way `SemanticSource.appSourceCode`
-- is one function. An unrecognised label returns null and therefore matches
-- nothing, which fails closed.
--
-- The real fix is for the two columns to share a vocabulary; that is an app
-- change and a backfill, and this exists so the feed is correct meanwhile.
create or replace function private.gender_key(p_label text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case btrim(p_label)
    when 'Male'       then 'male'
    when 'Female'     then 'female'
    when 'Non-binary' then 'nonbinary'
    else null
  end;
$$;

comment on function private.gender_key(text) is
  'users.sex holds Gender.label; users.interested_in holds Gender.rawValue. '
  'lower() bridges Male and Female and silently fails Non-binary/nonbinary. '
  'Unrecognised labels return null and match nothing.';

-- **The named hole.** §10 requires discovery to enforce mutual block; the
-- product has no blocking feature, so this is the one place that will change
-- when it does. Returning false is honest — nobody is blocked because blocking
-- does not exist — and is not a loosening of anything that exists today.
create or replace function private.is_blocked(p_a uuid, p_b uuid)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select false;
$$;

comment on function private.is_blocked(uuid, uuid) is
  'STUB — always false. Blocking is unbuilt: no table, no UI. Section 10 of the '
  'integration plan requires mutual-block enforcement on every discovery '
  'request, and this is the single body to replace when blocking ships.';

create or replace function api.discover_profiles(
  p_limit integer default 20,
  p_cursor_updated_at timestamptz default null,
  p_cursor_user_id uuid default null
)
returns table (
  user_id uuid,
  display_name text,
  age integer,
  district text,
  photo_seeds integer[],
  photo_paths text[],
  interests jsonb,
  domains jsonb,
  top_subjects jsonb,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  viewer uuid := (select auth.uid());
  viewer_key text;
  viewer_prefs text[];
  page_size integer := least(greatest(coalesce(p_limit, 20), 1), 50);
begin
  -- The flag first, so a disabled surface costs one lookup rather than a scan,
  -- and so the refusal is the same one every other surface gives.
  perform semantic_private.assert_surface_allowed('matching');

  if viewer is null then
    raise exception 'not signed in' using errcode = 'insufficient_privilege';
  end if;

  select private.gender_key(u.sex), u.interested_in
    into viewer_key, viewer_prefs
    from public.users u
   where u.id = viewer;

  -- **Not an error, and not everybody.** Somebody who has not finished
  -- onboarding has no gender and no preference, and the honest answer is an
  -- empty feed rather than an unfiltered one.
  if viewer_key is null or viewer_prefs is null or cardinality(viewer_prefs) = 0 then
    return;
  end if;

  return query
  select c.user_id, c.display_name, c.age, c.district, c.photo_seeds,
         c.photo_paths, c.interests, c.domains, c.top_subjects, c.updated_at
    from public.discovery_cards c
    join public.users u on u.id = c.user_id
   where c.user_id <> viewer
     -- Eligibility both ways: they are someone the viewer wants to see, and
     -- the viewer is someone they want to see. One direction alone is how a
     -- feed shows people who did not ask for it.
     and private.gender_key(u.sex) = any (viewer_prefs)
     and viewer_key = any (u.interested_in)
     and not private.is_blocked(viewer, c.user_id)
     -- **No photographs, no card** — the same rule `DiscoveryCardService.publish`
     -- applies on write, restated on read because a row can predate it.
     and coalesce(cardinality(c.photo_paths), 0) > 0
     -- A like is an invitation spent; the person leaves the feed. Only the
     -- viewer's own likes, because being liked by somebody does not answer
     -- them — admirers are a separate surface.
     and not exists (
       select 1 from public.likes l
        where l.liker_id = viewer and l.liked_id = c.user_id
     )
     -- **Keyset, never OFFSET.** Cards are republished on every distillation,
     -- so `updated_at` moves under a paging cursor constantly; an OFFSET would
     -- silently skip and repeat people. `user_id` breaks ties, the same reason
     -- message ordering had to break ties on `id`.
     and (
       p_cursor_updated_at is null
       or (c.updated_at, c.user_id) < (p_cursor_updated_at, p_cursor_user_id)
     )
   order by c.updated_at desc, c.user_id desc
   limit page_size;
end;
$$;

comment on function api.discover_profiles(integer, timestamptz, uuid) is
  'Server-owned discovery feed, scoped to auth.uid() with no parameter for '
  'whose. Gated on discovery_profile_reads via assert_surface_allowed(matching). '
  'Enforces two-way gender eligibility, own-like exclusion, photo presence and '
  'keyset paging. Blocking is stubbed (private.is_blocked) and there is no rate '
  'limit yet — both are section 10 requirements still outstanding.';

revoke all on function api.discover_profiles(integer, timestamptz, uuid) from public;
grant execute on function api.discover_profiles(integer, timestamptz, uuid) to authenticated;

-- **Behaviour, not text.** `0117` shipped a predicate that read an empty table
-- and its own check passed; the rule since is that an assertion must be able to
-- fail for the reason it exists.
do $$
declare
  ok boolean;
begin
  -- The vocabulary bridge, which is the part most likely to be wrong and least
  -- likely to announce it.
  if private.gender_key('Non-binary') is distinct from 'nonbinary' then
    raise exception 'gender_key does not bridge Non-binary';
  end if;
  if private.gender_key('Male') is distinct from 'male'
     or private.gender_key('Female') is distinct from 'female' then
    raise exception 'gender_key does not bridge the binary labels';
  end if;
  if private.gender_key('Wombat') is not null then
    raise exception 'gender_key must fail closed on an unknown label';
  end if;

  -- The surface must be shut. If this ever passes, the flag was enabled without
  -- the cohort decision Phase 4 requires.
  begin
    perform semantic_private.assert_surface_allowed('matching');
    raise exception 'matching surface is enabled; discovery_profile_reads should be false';
  exception
    when insufficient_privilege then
      null;  -- expected
  end;

  -- And the grant is the one the other api functions have.
  select has_function_privilege('authenticated',
    'api.discover_profiles(integer,timestamptz,uuid)', 'execute') into ok;
  if not ok then
    raise exception 'authenticated cannot execute the discovery rpc';
  end if;
  select has_function_privilege('anon',
    'api.discover_profiles(integer,timestamptz,uuid)', 'execute') into ok;
  if ok then
    raise exception 'anon can execute the discovery rpc';
  end if;
end
$$;

commit;
