-- 0409 — the strikes finally weigh.
--
-- **The owner's directive, 2026-08-26: rejection/calibration weights must
-- feed resolution and scoring — ordering, and confidence propagation
-- across related nodes.** The audit found the machinery half-built:
-- 0257's ledger holds 3,646 votes (3,301 strikes, 345 keeps — one
-- calibrator), the parameters and dry-run math stand, but the "published
-- release" the dry run refers to was never built and the scorer reads
-- none of it: `current_multiplier` has been a hardcoded 1.0 since the
-- day it was written. Keeps and strikes aggregated to nowhere.
--
-- This is Release D, plus its consumer:
--
-- 1. **`calibration_releases` / `calibration_release_multipliers`** —
--    immutable, versioned, one active. Rows are published at three
--    granularities the scorer can actually resolve for a mapping —
--    (source_code, action_type), (source_code), and global — each row
--    admitted only where its own stratum meets the parameters' support
--    floor, with the Beta(α,β) posterior keep-rate over the prior as
--    the multiplier, clamped to the parameters' bounds. The full
--    five-key strata stay the dry run's report; the scorer's lane is
--    the coarse one because a mapping knows its source and action.
-- 2. **`calibration_v1_bootstrap` parameters** — α=4, β=4, bounds
--    [0.5, 1.5], `min_distinct_users = 1`. The owner's standing
--    bootstrap ruling (the cutoff was fitted the same way): the one
--    calibrator's data is fitted explicitly and versionedly, floors
--    stay in `calibration_v1` for the fleet, and retiring the bootstrap
--    release the day five users exist is one publish call.
-- 3. **`calibration_multiplier(source_code, action_type)`** — `stable`,
--    resolves against the active release most-specific-first, answers
--    1.0 when nothing matches: absence is neutrality, never an error.
-- 4. **The scorer consumes it** (score.py 0.21.0, same change): the
--    evidence-weight formula gains the multiplier — BEFORE aggregation
--    and saturation, which is the point: λ propagation walks raw
--    pre-saturation weights, so a stratum users keep striking whispers
--    into every node it would have fed, and `surfacing_score` — the
--    page's `order by` — inherits it downstream. One insertion, both
--    of the owner's requirements.
--
-- The scorer version moves to 0.21.0 and the old row retires in this
-- migration (never two active); the release publish ends with the
-- recompute enqueue, and so does every future publish — a calibration
-- release is an analysis change (0396's rule).

begin;

-- ---------------------------------------------------------------------
-- The release tables.
-- ---------------------------------------------------------------------
create table semantic_private.calibration_releases (
  id uuid primary key default gen_random_uuid(),
  version text not null unique,
  parameters_version text not null
    references semantic_private.calibration_parameters (version),
  decision_watermark timestamptz not null,
  published_at timestamptz not null default now(),
  status text not null default 'active'
    check (status in ('active', 'retired'))
);
create unique index calibration_releases_one_active
  on semantic_private.calibration_releases ((true)) where status = 'active';

create table semantic_private.calibration_release_multipliers (
  id uuid primary key default gen_random_uuid(),
  release_id uuid not null references semantic_private.calibration_releases (id),
  source_code text,
  action_type text,
  keeps integer not null,
  strikes integer not null,
  distinct_users integer not null,
  multiplier numeric not null
);

create or replace function semantic_private.calibration_rows_append_only()
returns trigger
language plpgsql
as $$
begin
  raise exception 'calibration release rows are immutable';
end;
$$;
create trigger calibration_release_multipliers_append_only
  before update or delete on semantic_private.calibration_release_multipliers
  for each row execute function semantic_private.calibration_rows_append_only();

revoke all on semantic_private.calibration_releases from public;
revoke all on semantic_private.calibration_release_multipliers from public;
grant select on semantic_private.calibration_releases to semantic_worker;
grant select on semantic_private.calibration_release_multipliers to semantic_worker;

-- ---------------------------------------------------------------------
-- The bootstrap parameters: the owner's n=1 ruling, versioned.
-- ---------------------------------------------------------------------
insert into semantic_private.calibration_parameters values
  ('calibration_v1_bootstrap', 4, 4, 1, 0.5, 1.5,
   array['source_code,action_type', 'source_code', ''])
on conflict (version) do nothing;

-- ---------------------------------------------------------------------
-- The publish.
-- ---------------------------------------------------------------------
create or replace function semantic_private.publish_calibration_release(
  p_parameters text, p_release_version text)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  prm record;
  watermark timestamptz;
  release_id uuid;
  rows_published integer;
begin
  select * into strict prm
    from semantic_private.calibration_parameters where version = p_parameters;
  select coalesce(max(decided_at), 'epoch'::timestamptz) into watermark
    from semantic_private.calibration_effective_decisions;

  update semantic_private.calibration_releases
     set status = 'retired' where status = 'active';

  insert into semantic_private.calibration_releases
    (version, parameters_version, decision_watermark)
  values (p_release_version, p_parameters, watermark)
  returning id into release_id;

  with votes as (
    select distinct l.user_id, l.review_item_id, l.independence_root,
           l.source_code, l.action_type, l.calibration_vote
      from semantic_private.calibration_feedback_ledger l
     where l.calibration_vote in ('positive', 'negative')
  ), strata as (
    select v.source_code, v.action_type,
           count(*) filter (where v.calibration_vote = 'positive') as keeps,
           count(*) filter (where v.calibration_vote = 'negative') as strikes,
           count(distinct v.user_id) as distinct_users
      from votes v
     group by grouping sets ((v.source_code, v.action_type),
                             (v.source_code), ())
  )
  insert into semantic_private.calibration_release_multipliers
    (release_id, source_code, action_type, keeps, strikes,
     distinct_users, multiplier)
  select release_id, s.source_code, s.action_type, s.keeps, s.strikes,
         s.distinct_users,
         least(greatest(
           ((s.keeps + prm.alpha) / (s.keeps + s.strikes + prm.alpha + prm.beta))
             / (prm.alpha / (prm.alpha + prm.beta)),
           prm.min_multiplier), prm.max_multiplier)
    from strata s
   where s.distinct_users >= prm.min_distinct_users
     and (s.keeps + s.strikes) > 0;
  get diagnostics rows_published = row_count;

  perform semantic_private.enqueue_recompute_on_analysis_change(
    'calibration release ' || p_release_version || ' (' || p_parameters
    || '): ' || rows_published || ' multiplier row(s)');
  return release_id;
end;
$function$;

revoke execute on function
  semantic_private.publish_calibration_release(text, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The resolver the scorer calls: most specific match, 1.0 for silence.
-- ---------------------------------------------------------------------
create or replace function semantic_private.calibration_multiplier(
  p_source_code text, p_action_type text)
returns numeric
language sql
stable
set search_path to ''
as $function$
  select coalesce((
    select m.multiplier
      from semantic_private.calibration_release_multipliers m
      join semantic_private.calibration_releases r
        on r.id = m.release_id and r.status = 'active'
     where (m.source_code is not distinct from p_source_code
              and m.action_type is not distinct from p_action_type)
        or (m.source_code is not distinct from p_source_code
              and m.action_type is null)
        or (m.source_code is null and m.action_type is null)
     order by (m.source_code is not null)::int
              + (m.action_type is not null)::int desc
     limit 1), 1.0);
$function$;

grant execute on function
  semantic_private.calibration_multiplier(text, text) to semantic_worker;

-- ---------------------------------------------------------------------
-- Scorer 0.21.0: the formula gains the multiplier (score.py, same
-- change). New model row active, old retired — never two active.
-- ---------------------------------------------------------------------
do $$
declare
  old_row record;
begin
  select * into old_row from ontology.model_versions
   where model_role = 'scorer' and status = 'active'
   order by created_at desc limit 1;
  if old_row.id is null then
    raise notice '0409: no active scorer stands; the model rows wait';
  else
    update ontology.model_versions set status = 'retired'
     where id = old_row.id;
    insert into ontology.model_versions
      (id, model_key, version, model_role, status, parameters)
    values (extensions.gen_random_uuid(), old_row.model_key,
            '0.21.0', 'scorer', 'active',
            coalesce(old_row.parameters, '{}'::jsonb)
              || jsonb_build_object('calibration',
                   'evidence weight multiplied by the active calibration '
                   || 'release''s (source, action) multiplier before '
                   || 'aggregation; propagation and ordering inherit it'));
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- The bootstrap release publishes now, over whatever the ledger holds.
-- On an empty database this publishes zero rows and every multiplier
-- resolves 1.0 — the transformation asserted, not the precondition.
-- ---------------------------------------------------------------------
do $$
declare rid uuid;
begin
  select semantic_private.publish_calibration_release(
    'calibration_v1_bootstrap', 'release-bootstrap-1') into rid;
  raise notice '0409: bootstrap release published as %', rid;
end;
$$;

commit;
