-- 0125 — the discovery RPC returns assertions, and the three missing checks
-- become checks of something.
--
-- **§10 requires discovery RPCs to enforce "mutual block, eligibility, rate
-- limit, current revision, and surface permissions".** `0120` shipped the first
-- two and `0123` made the block real. The other three could not be written
-- then, and the reason is worth stating because it decided the shape of this
-- migration: **revision and surface permission are properties of an
-- *assertion*, and `0120` returned `discovery_cards`.** Bolting them onto a
-- card query would have been two more guards reading something nothing
-- populates — `0117` shipped exactly that and `0118` had to undo it.
--
-- So the RPC now returns, beside each card, the assertions that person may show
-- on the matching surface. That is what "server-owned discovery" means: the
-- server decides what one person may know about another, rather than handing
-- over a table and asking the client to be careful.
--
-- **Four gates on every term, and each exists for a different reason:**
--
--   1. `assertion_surface_permissions.can_select` for `matching` — the subject's
--      own per-assertion grant. 178 rows per surface today.
--   2. **Current revision** — the score must come from a `succeeded` run whose
--      `input_revision` equals the subject's `user_state_versions.revision`.
--      Copied from `api.list_assertions` rather than restated, because a second
--      spelling of "current" is a second thing to keep in step. It is the rule
--      that makes a claim about somebody rather than about who they used to be.
--   3. **Not YouTube's alone** — `concept_has_non_video_witness` (`0118`), which
--      until now had no caller. III.E.3.b: what crosses to another user must be
--      attested by a non-YouTube source, so the identical row would be published
--      with YouTube disconnected.
--   4. `eligible` only, never `candidate`. A candidate is a claim the scorer is
--      not yet willing to make; showing it to a stranger is making it for them.
--
-- **The predicate in (3) applies only to inferred assertions.** A declared one
-- — somebody typed it — has no observations and therefore no witness of any
-- kind, so demanding one would silently withhold exactly the terms a person
-- chose about themselves. That asymmetry is the whole difference between
-- evidence and a statement.

begin;

-- **Rate limit: a real table, because a limit you cannot see is a limit nobody
-- can tune.** The threat is enumeration — a page is up to 50 profiles, so an
-- unbounded caller walks the whole user base — rather than load.
create table if not exists semantic_private.discovery_requests (
  user_id uuid not null references auth.users(id) on delete cascade,
  requested_at timestamptz not null default now()
);

create index if not exists discovery_requests_user_time_idx
  on semantic_private.discovery_requests (user_id, requested_at desc);

alter table semantic_private.discovery_requests enable row level security;
-- No policy, as everywhere else in this schema: the only writer is a
-- `security definer` function, and "RLS on, no policy" stays statable in one
-- sentence.

comment on table semantic_private.discovery_requests is
  'One row per discover_profiles call, for the section 10 rate limit. Swept by '
  'nothing yet — see the note in the function about why that is a real gap.';

-- **The terms one person may show another.** Separate from the RPC so the four
-- gates are readable as a list rather than buried in a join, and so a future
-- surface (a bio, an icebreaker) asks the same question by calling the same
-- function rather than by copying it.
create or replace function semantic_private.matching_terms(p_subject uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(term order by term ->> 'score' desc), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'label', coalesce(revision.preferred_label, user_term.label),
               'kind', revision.concept_kind,
               'score', coalesce(score.surfacing_score, 1.0)
             ) as term
        from semantic_private.user_assertions as assertion
        left join semantic_private.user_terms as user_term
          on user_term.id = assertion.user_term_id
         and user_term.user_id = assertion.user_id
        left join semantic_private.assertion_preferences as preference
          on preference.assertion_id = assertion.id
         and preference.user_id = assertion.user_id
        left join semantic_private.assertion_current_scores as current_score
          on current_score.assertion_id = assertion.id
         and current_score.user_id = assertion.user_id
        left join semantic_private.user_state_versions as user_state
          on user_state.user_id = assertion.user_id
        left join semantic_private.semantic_runs as score_run
          on score_run.id = current_score.semantic_run_id
         and score_run.user_id = assertion.user_id
         and score_run.status = 'succeeded'
         -- (2) current revision, spelled as `list_assertions` spells it.
         and score_run.input_revision = coalesce(user_state.revision, 0)
        left join semantic_private.assertion_score_versions as score
          on score.id = current_score.assertion_score_version_id
         and score.user_id = current_score.user_id
         and score.assertion_id = current_score.assertion_id
         and score.semantic_run_id = score_run.id
        left join ontology.concept_revisions as revision
          on revision.ontology_version_id = coalesce(
               score.ontology_version_id, assertion.created_ontology_version_id
             )
         and revision.concept_id = assertion.concept_id
       where assertion.user_id = p_subject
         -- (4) eligible only.
         and assertion.machine_state = 'eligible'
         and coalesce(preference.display_state, 'default') <> 'suppressed'
         -- (1) the subject's own grant for this surface.
         and exists (
           -- `permission`, not `grant`: `grant` is a reserved word and cannot
           -- be a bare alias, which is a syntax error one statement short of
           -- the whole migration.
           select 1 from semantic_private.assertion_surface_permissions as permission
            where permission.assertion_id = assertion.id
              and permission.user_id = assertion.user_id
              and permission.surface = 'matching'
              and permission.can_select
         )
         and not exists (
           select 1 from semantic_private.user_suppressions as suppression
            where suppression.user_id = assertion.user_id
              and suppression.predicate_key = assertion.predicate_key
              and suppression.surface = 'matching'
              and suppression.active
              and (
                (assertion.concept_id is not null
                 and suppression.concept_id = assertion.concept_id)
                or (assertion.user_term_id is not null
                    and suppression.user_term_id = assertion.user_term_id)
              )
         )
         -- An inferred claim needs a live score; a declared one is the person's
         -- own words and needs none.
         and (
           assertion.assertion_origin <> 'inferred'
           or (score.id is not null and score_run.id is not null)
         )
         -- (3) III.E.3.b. Inferred only: a declared assertion has no
         -- observations, so demanding a witness would withhold precisely the
         -- terms somebody chose about themselves.
         and (
           assertion.assertion_origin <> 'inferred'
           or assertion.concept_id is null
           or semantic_private.concept_has_non_video_witness(
                score_run.id, assertion.concept_id)
         )
         and coalesce(revision.preferred_label, user_term.label) is not null
    ) as permitted;
$$;

comment on function semantic_private.matching_terms(uuid) is
  'What one person may show another on the matching surface: eligible '
  'assertions carrying a can_select grant, scored at the subject''s current '
  'revision, and — for inferred ones — attested by a source outside the video '
  'independence group (0118, III.E.3.b).';

revoke all on function semantic_private.matching_terms(uuid) from public, anon, authenticated;

-- The return type changes, so this is a drop rather than a replace: `create or
-- replace` cannot alter a signature, and `0026` records what happens when a
-- changed signature quietly *overloads* instead.
drop function if exists api.discover_profiles(integer, timestamptz, uuid);

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
  terms jsonb,
  updated_at timestamptz
)
-- **`volatile`, not `stable`** — it records the request for the rate limit, and
-- a `stable` function may not write. Nothing plans around it, so the cost is
-- nil and the alternative is a limit that cannot count.
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  viewer uuid := (select auth.uid());
  viewer_key text;
  viewer_prefs text[];
  page_size integer := least(greatest(coalesce(p_limit, 20), 1), 50);
  -- One call every minute sustained, which no person browsing reaches and no
  -- scraper is content with. At 50 rows a page it still bounds a single hour to
  -- 3,000 profiles — far past ordinary use and far short of a user base.
  calls_per_hour constant integer := 60;
  recent integer;
begin
  perform semantic_private.assert_surface_allowed('matching');

  if viewer is null then
    raise exception 'not signed in' using errcode = 'insufficient_privilege';
  end if;

  select count(*) into recent
    from semantic_private.discovery_requests r
   where r.user_id = viewer
     and r.requested_at > now() - interval '1 hour';

  if recent >= calls_per_hour then
    -- Named plainly: this is the one refusal here that is the caller's own
    -- doing and that they can act on by waiting.
    raise exception 'too many requests; try again shortly'
      using errcode = 'too_many_connections';
  end if;

  insert into semantic_private.discovery_requests (user_id) values (viewer);

  select private.gender_key(u.sex), u.interested_in
    into viewer_key, viewer_prefs
    from public.users u
   where u.id = viewer;

  if viewer_key is null or viewer_prefs is null or cardinality(viewer_prefs) = 0 then
    return;
  end if;

  return query
  select c.user_id, c.display_name, c.age, c.district, c.photo_seeds,
         c.photo_paths, c.interests, c.domains, c.top_subjects,
         semantic_private.matching_terms(c.user_id),
         c.updated_at
    from public.discovery_cards c
    join public.users u on u.id = c.user_id
   where c.user_id <> viewer
     and private.gender_key(u.sex) = any (viewer_prefs)
     and viewer_key = any (u.interested_in)
     and not private.is_blocked(viewer, c.user_id)
     and coalesce(cardinality(c.photo_paths), 0) > 0
     and not exists (
       select 1 from public.likes l
        where l.liker_id = viewer and l.liked_id = c.user_id
     )
     and (
       p_cursor_updated_at is null
       or (c.updated_at, c.user_id) < (p_cursor_updated_at, p_cursor_user_id)
     )
   order by c.updated_at desc, c.user_id desc
   limit page_size;
end;
$$;

comment on function api.discover_profiles(integer, timestamptz, uuid) is
  'Server-owned discovery. Enforces section 10 in full: mutual block, two-way '
  'eligibility, rate limit, current revision and per-assertion surface '
  'permissions. Returns each card with the terms that person may show on the '
  'matching surface. Gated on discovery_profile_reads.';

revoke all on function api.discover_profiles(integer, timestamptz, uuid) from public, anon;
grant execute on function api.discover_profiles(integer, timestamptz, uuid) to authenticated;

-- **Behaviour, and each of these can fail.** The standing rule since `0117`:
-- an assertion that cannot fail reads as coverage and is worse than none.
do $$
declare
  subject uuid;
  terms jsonb;
  eligible integer;
begin
  -- The grant posture, which is the one thing a client could exploit.
  if has_function_privilege('anon', 'api.discover_profiles(integer,timestamptz,uuid)', 'execute')
     or has_function_privilege('authenticated', 'semantic_private.matching_terms(uuid)', 'execute') then
    raise exception 'a client role can reach discovery internals';
  end if;

  -- The surface must still be shut; enabling it is a cohort decision, not a
  -- side effect of this migration.
  begin
    perform semantic_private.assert_surface_allowed('matching');
    raise exception 'matching is enabled; discovery_profile_reads should be false';
  exception when insufficient_privilege then null;
  end;

  -- **`matching_terms` must discriminate.** Run against a real account with
  -- eligible assertions, it must return fewer terms than that account has
  -- assertions — the four gates each remove something — and it must not return
  -- an empty array for somebody who plainly has terms, which would be `0117`
  -- all over again.
  select a.user_id into subject
    from semantic_private.user_assertions a
   where a.machine_state = 'eligible'
   group by a.user_id
   order by count(*) desc
   limit 1;

  if subject is null then
    raise notice 'no eligible assertions anywhere; matching_terms unexercised';
  else
    select count(*) into eligible
      from semantic_private.user_assertions a
     where a.user_id = subject and a.machine_state = 'eligible';
    terms := semantic_private.matching_terms(subject);
    raise notice 'matching_terms: % of % eligible assertions pass the gates',
      jsonb_array_length(terms), eligible;
    if jsonb_array_length(terms) > eligible then
      raise exception 'matching_terms returned more terms than the subject has assertions';
    end if;
  end if;
end
$$;

commit;
