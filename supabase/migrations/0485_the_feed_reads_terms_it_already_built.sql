-- ---------------------------------------------------------------------------
-- The feed reads terms it already built, instead of building them per viewer
-- ---------------------------------------------------------------------------
--
-- Measured 2026-11-05 on production: `api.discover_profiles` failed every call
-- with 57014 (statement timeout) and Explore showed "Nobody to see yet". The
-- feed itself is unchanged since `0125`; what grew is
-- `semantic_private.matching_terms`, which it calls once per card. Three cards,
-- 561–834 eligible assertions each, and one call took **4.4 s and 6.4 s** for
-- two of them — so a viewer with only two candidates already needed ~11 s
-- against `authenticated`'s `statement_timeout = 8s`.
--
-- EXPLAIN ANALYZE of the body found no single slow node: the cost is spread
-- across ~830 rows of per-term work (the ontology climbs, `bio_category`,
-- `work_medium_from_evidence`, the witness and suppression probes). No index
-- fixes that. What fixes it is computing a person's terms once and reading
-- them many times.
--
-- **A cache that can serve a suppressed term is worse than a slow feed**, so
-- freshness is not left to a TTL. Every write to any of the thirteen tables
-- `matching_terms` reads (directly or through its helpers) bumps that
-- person's generation *in the same transaction*, and a cached row is served
-- only while its generation still matches. That is correct across the race
-- that matters — a strike committing while a recompute is in flight: the
-- generation is read before `matching_terms` runs, so either the recompute's
-- snapshot already sees the strike, or the strike's bump arrives after and
-- the stored row is born stale.
--
-- The revision was the obvious key and is the wrong one: checked on
-- production, none of the eight functions that write `assertion_preferences`
-- or `user_suppressions` touches `user_state_versions`, so a hide does not
-- move it.
--
-- An ontology publish changes labels and categories for everybody, so the
-- four ontology tables bump every generation, per statement. The 24-hour TTL
-- is a backstop for a dependency added later and missed here, not the
-- mechanism.
--
-- Built in two places. A pg_cron job every minute rebuilds stale rows for
-- everyone with a card, committing per person so no row lock outlives one
-- recompute. And the feed itself builds at most what fits its budget: it
-- starts a recompute only in its first second, since one can take 6.4 s and
-- the statement dies at 8. A card whose terms are not ready is sent with `[]`
-- rather than with stale terms — never the other way round.
--
-- `matching_terms` itself is untouched; this wraps whatever it returns.
-- ---------------------------------------------------------------------------

create table semantic_private.matching_terms_generations (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  generation bigint not null default 0
);

create table semantic_private.matching_terms_cache (
  user_id     uuid primary key references auth.users (id) on delete cascade,
  generation  bigint not null,
  terms       jsonb not null,
  computed_at timestamptz not null default now()
);

-- RLS on and no policies, like everything in this schema: access is the
-- security definer functions below and nothing else.
alter table semantic_private.matching_terms_generations enable row level security;
alter table semantic_private.matching_terms_cache enable row level security;
revoke all on table semantic_private.matching_terms_generations from public, anon, authenticated;
revoke all on table semantic_private.matching_terms_cache from public, anon, authenticated;

-- **Guarded on the owner existing, because these fire on account deletion.**
-- Every table below cascades from `auth.users`, and a row trigger fires on a
-- cascaded delete exactly as on a direct one — by then the user row is gone,
-- so an unguarded insert here would fail the foreign key and make the account
-- undeletable (`0204`'s lesson). An update of a row that still exists is
-- harmless; the cascade removes it a moment later.
create or replace function semantic_private.bump_matching_terms_generation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  subjects uuid[];
  subject uuid;
begin
  subjects := case tg_op
    when 'INSERT' then array[new.user_id]
    when 'DELETE' then array[old.user_id]
    else array[new.user_id, old.user_id]
  end;
  foreach subject in array subjects loop
    continue when subject is null;
    insert into semantic_private.matching_terms_generations as g (user_id, generation)
    select subject, 1
     where exists (select 1 from auth.users u where u.id = subject)
    on conflict (user_id) do update set generation = g.generation + 1;
  end loop;
  return null;
end;
$$;
revoke all on function semantic_private.bump_matching_terms_generation()
  from public, anon, authenticated;

create or replace function semantic_private.bump_all_matching_terms_generations()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update semantic_private.matching_terms_generations
     set generation = generation + 1;
  return null;
end;
$$;
revoke all on function semantic_private.bump_all_matching_terms_generations()
  from public, anon, authenticated;

do $$
declare
  t text;
begin
  -- Read off the live definitions on 2026-11-05: `matching_terms` and the
  -- helpers it calls (`bio_category`, `concept_block`, `concept_hub`,
  -- `concept_has_non_video_witness`, `work_medium_from_evidence`). Anything a
  -- later migration teaches them to read belongs in this list too.
  foreach t in array array[
    'user_assertions', 'user_terms', 'assertion_preferences',
    'assertion_current_scores', 'assertion_score_versions',
    'user_suppressions', 'assertion_surface_permissions', 'semantic_runs',
    'user_state_versions', 'concept_source_scores', 'observations',
    'candidate_support_links', 'user_term_candidates'
  ] loop
    execute format(
      'create trigger matching_terms_generation
         after insert or update or delete on semantic_private.%I
         for each row execute function semantic_private.bump_matching_terms_generation()',
      t);
  end loop;

  foreach t in array array['concepts', 'concept_revisions', 'concept_edges', 'versions'] loop
    execute format(
      'create trigger matching_terms_generation
         after insert or update or delete on ontology.%I
         for each statement execute function semantic_private.bump_all_matching_terms_generations()',
      t);
  end loop;
end;
$$;

-- The one way to read a person's terms for another viewer. `p_compute` false
-- answers only from the cache and returns null on a miss, so a caller can tell
-- "not ready" from "has none".
create or replace function semantic_private.cached_matching_terms(
  p_subject uuid,
  p_compute boolean
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  current_generation bigint;
  hit jsonb;
  fresh jsonb;
begin
  -- The row must exist before it is read, or an ontology bump — which only
  -- updates rows that exist — would leave a cached row at 0 looking current.
  insert into semantic_private.matching_terms_generations (user_id)
  select p_subject
   where exists (select 1 from auth.users u where u.id = p_subject)
  on conflict (user_id) do nothing;

  select g.generation into current_generation
    from semantic_private.matching_terms_generations g
   where g.user_id = p_subject;
  if current_generation is null then
    return '[]'::jsonb;
  end if;

  select c.terms into hit
    from semantic_private.matching_terms_cache c
   where c.user_id = p_subject
     and c.generation = current_generation
     and c.computed_at > now() - interval '24 hours';
  if found then
    return hit;
  end if;

  if not p_compute then
    return null;
  end if;

  -- A separate statement, so a separate snapshot taken *after* the generation
  -- was read. See the header for why that ordering is the whole argument.
  fresh := semantic_private.matching_terms(p_subject);

  insert into semantic_private.matching_terms_cache as c
         (user_id, generation, terms, computed_at)
  values (p_subject, current_generation, fresh, clock_timestamp())
  on conflict (user_id) do update
     set generation = excluded.generation,
         terms = excluded.terms,
         computed_at = excluded.computed_at;
  return fresh;
end;
$$;
revoke all on function semantic_private.cached_matching_terms(uuid, boolean)
  from public, anon, authenticated;

-- A procedure, not a function, so it can commit per person: the job holds a
-- cache row's lock for one recompute at most, rather than for its whole run,
-- and a viewer computing the same person never waits behind the batch.
-- Not `security definer` and no `set search_path` — a procedure carrying
-- either may not commit — and it needs neither: pg_cron runs it as the owner,
-- and every name below is schema-qualified.
create or replace procedure semantic_private.refresh_matching_terms_cache(
  p_budget interval default interval '40 seconds'
)
language plpgsql
as $$
declare
  started constant timestamptz := clock_timestamp();
  subject uuid;
begin
  for subject in
    select c.user_id
      from public.discovery_cards c
     where coalesce(cardinality(c.photo_paths), 0) > 0
     order by c.updated_at desc, c.user_id desc
  loop
    exit when clock_timestamp() - started > p_budget;
    if semantic_private.cached_matching_terms(subject, false) is null then
      perform semantic_private.cached_matching_terms(subject, true);
    end if;
    commit;
  end loop;
end;
$$;
revoke all on procedure semantic_private.refresh_matching_terms_cache(interval)
  from public, anon, authenticated;

select cron.schedule(
  'matching-terms-cache-refresh',
  '* * * * *',
  $$call semantic_private.refresh_matching_terms_cache()$$
);

-- `0125`'s body, with two changes and nothing else: the page is chosen first
-- and terms are fetched only for the rows on it, and they come from the cache
-- within a budget instead of being recomputed for every card.
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
  calls_per_hour constant integer := 60;
  recent integer;
  -- One recompute can take 6.4 s and the statement dies at 8 s, so a
  -- recompute may only *start* inside the first second.
  compute_until constant timestamptz := clock_timestamp() + interval '1 second';
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
  select page.user_id, page.display_name, page.age, page.district,
         page.photo_seeds, page.photo_paths, page.interests, page.domains,
         page.top_subjects,
         coalesce(
           semantic_private.cached_matching_terms(
             page.user_id, clock_timestamp() < compute_until),
           '[]'::jsonb),
         page.updated_at
    from (
      select c.user_id, c.display_name, c.age, c.district, c.photo_seeds,
             c.photo_paths, c.interests, c.domains, c.top_subjects, c.updated_at
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
       limit page_size
    ) as page
   order by page.updated_at desc, page.user_id desc;
end;
$$;

-- **Behaviour, asserted on whatever the database holds.** For one person with
-- a card: the cache equals a live `matching_terms`, and both trigger
-- functions invalidate it.
--
-- The invalidation probes write to a temporary table carrying the same two
-- trigger functions, never to a real one: the real tables are guarded
-- (`user_state_versions` refuses any update that does not advance the
-- revision by exactly one) and some fire recomputes. The real attachments are
-- asserted from the catalog instead — seventeen of them, by name.
create temporary table matching_terms_probe (user_id uuid);
create trigger probe_row
  after insert on matching_terms_probe
  for each row execute function semantic_private.bump_matching_terms_generation();
create trigger probe_statement
  after update on matching_terms_probe
  for each statement execute function semantic_private.bump_all_matching_terms_generations();

do $$
declare
  subject uuid;
  cached jsonb;
  live jsonb;
  attached integer;
begin
  select count(*) into attached
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
   where t.tgname = 'matching_terms_generation'
     and n.nspname in ('semantic_private', 'ontology');
  if attached <> 17 then
    raise exception 'expected 17 matching_terms_generation triggers, found %', attached;
  end if;

  select c.user_id into subject
    from public.discovery_cards c
    join semantic_private.user_state_versions s on s.user_id = c.user_id
   order by c.updated_at desc
   limit 1;
  if subject is null then
    raise notice 'no card with semantic state; cache unexercised';
    return;
  end if;

  cached := semantic_private.cached_matching_terms(subject, true);
  live := semantic_private.matching_terms(subject);
  if cached is distinct from live then
    raise exception 'cached terms differ from live matching_terms for %', subject;
  end if;
  if semantic_private.cached_matching_terms(subject, false) is null then
    raise exception 'a just-computed cache row was not served';
  end if;

  -- A per-person write invalidates that person.
  insert into pg_temp.matching_terms_probe (user_id) values (subject);
  if semantic_private.cached_matching_terms(subject, false) is not null then
    raise exception 'invalidation failed: a row write left the cache current';
  end if;

  -- Re-warm, then an ontology-style statement invalidates everybody.
  perform semantic_private.cached_matching_terms(subject, true);
  update pg_temp.matching_terms_probe set user_id = user_id;
  if semantic_private.cached_matching_terms(subject, false) is not null then
    raise exception 'invalidation failed: a statement write left the cache current';
  end if;

  -- Leave it warm for the first viewer.
  perform semantic_private.cached_matching_terms(subject, true);
end;
$$;

drop table pg_temp.matching_terms_probe;
