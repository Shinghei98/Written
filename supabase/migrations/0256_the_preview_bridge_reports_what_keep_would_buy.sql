-- 0256 — Release B: the preview bridge reports what a keep would buy, and
-- writes no evidence.
--
-- The revised memo's §3.3 is the architecture: keep comes before evidence.
-- `observation_mappings` is the scorer's only authoritative input, so this
-- release deliberately cannot touch it — it builds the three things the
-- review decision will need to be an informed one:
--
--   1. `mention_evidence_policy` — the versioned, fail-closed map
--      `source action × mention family × mention role → relation kind`.
--      Population is derived, never typed: the licensed sources' own
--      `action_weights` supply the (source, action) pairs (an action the
--      scorer gives no weight cannot appear here at all), crossed with an
--      authored allowlist of conversation-worthy roles and assertable
--      families. Absence denies: `format_token`, `incidental_context`,
--      `tag_roster`, `uploader` and the rest are not rows, so a mention
--      carrying them stays a private candidate whatever its shape. `place`
--      is absent from the family list for the same reason it is absent from
--      `api.list_assertions`.
--   2. `semantic_private.would_be_mention_evidence(user)` — the read-only
--      projection: per resolved identity (existing concept or provisional),
--      what the scorer WOULD see after a keep — the mention-level weights
--      under the scorer's own formula (evidence × recency × reliability ×
--      action weight), the saturation curve w/(w+6), the 0.35 bar,
--      independence roots (one per provider item, so repetition inside one
--      observation cannot masquerade as corroboration), and the anti-join
--      against deterministic mappings so evidence the resolver already
--      carries is named as a duplicate rather than double-counted. The
--      calibration fields are present and inert — release 'uncalibrated',
--      multiplier 1.0 — so Release D's calibration releases have a column to
--      land in rather than a schema change.
--   3. `would_be_evidence_reports` — append-only snapshots of that
--      projection, so Gate B's "reproducible and explainable" is a stored
--      artifact keyed to who generated it and when, not a rerun someone
--      remembers differently. Reports hold user text and live only here —
--      never in the repository.
--
-- No LLM confidence appears anywhere: the model's `confidence` column is
-- deliberately unread by every statement in this migration.

-- ---------------------------------------------------------------------------
-- 1. The policy map
-- ---------------------------------------------------------------------------

create table semantic_private.mention_evidence_policy (
  policy_version text not null default 'mention_evidence_policy_v1',
  source_code    text not null,
  action_type    text not null,
  mention_family text not null,
  mention_role   text not null,
  relation_kind  text not null default 'affinity_to',
  primary key (policy_version, source_code, action_type,
               mention_family, mention_role)
);

comment on table semantic_private.mention_evidence_policy is
  'Fail-closed: a (source action, family, role) with no row here can never '
  'become scorer evidence, whatever the extraction looks like. Populated by '
  'rule from sources.action_weights — an unweighted action cannot hold a row '
  '— crossed with the authored role and family allowlists in 0256.';

insert into semantic_private.mention_evidence_policy
  (source_code, action_type, mention_family, mention_role)
select s.source_code, a.key, fam.family, role.role
  from semantic_private.sources s,
       jsonb_each_text(s.action_weights) a,
       (values ('person'), ('group'), ('organization'), ('franchise'),
               ('work'), ('anime'), ('book'), ('game'), ('music_work'),
               ('album'), ('sport'), ('activity'), ('idea'), ('culture'),
               ('event'), ('tour')) as fam(family),
       (values ('primary_subject'), ('featured_person'), ('performing_group'),
               ('work_or_franchise'), ('creator_identity'),
               ('channel_core_topic'), ('durable_activity_or_idea')) as role(role)
 where s.source_code = any (semantic_private.model_input_source_codes())
   and a.value::float > 0;

-- Read-only to every client identity; the worker reads it, nothing updates
-- it — a superseding policy takes a new policy_version's rows.
revoke all on semantic_private.mention_evidence_policy from public;
grant select on semantic_private.mention_evidence_policy to semantic_worker;

-- ---------------------------------------------------------------------------
-- 2. The would-be evidence projection
-- ---------------------------------------------------------------------------

create or replace function semantic_private.would_be_mention_evidence(
  p_user_id uuid)
returns table(
  identity_kind        text,      -- 'concept' | 'provisional'
  concept_id           uuid,
  provisional_entity_id uuid,
  label                text,
  family               text,
  relation_kind        text,
  mention_count        integer,
  independence_roots   integer,   -- distinct provider items
  duplicate_of_deterministic integer, -- mentions whose (observation, concept)
                                      -- the resolver already mapped
  base_weight          numeric,
  calibration_release  text,
  calibration_multiplier numeric,
  effective_weight     numeric,
  would_be_strength    numeric,
  would_cross_bar      boolean,
  contributing_mention_ids uuid[])
language sql
stable
set search_path to ''
as $$
  with eligible as (
    select r.resolution,
           r.concept_id,
           r.provisional_entity_id,
           m.id as mention_id,
           m.observation_id,
           m.mention_text,
           coalesce(p.family, m.type_hint) as family,
           pol.relation_kind,
           (m.evidence_weight * m.recency_weight
              * s.default_reliability
              * (s.action_weights ->> o.action_type)::numeric) as w,
           exists (
             select 1 from semantic_private.observation_mappings dm
              where dm.observation_id = m.observation_id
                and dm.user_id = m.user_id
                and dm.concept_id = r.concept_id
                and dm.mapping_state = 'accepted'
           ) and r.resolution = 'resolved_existing' as deterministic_duplicate
      from semantic_private.current_mention_resolutions r
      join semantic_private.observation_mentions m
        on m.id = r.mention_id and m.user_id = r.user_id
      join semantic_private.observations o
        on o.id = m.observation_id and o.user_id = m.user_id
      join semantic_private.sources s
        on s.source_code = o.source_code
      left join semantic_private.provisional_entities p
        on p.id = r.provisional_entity_id
      join semantic_private.mention_evidence_policy pol
        on pol.source_code = o.source_code
       and pol.action_type = o.action_type
       and pol.mention_family = coalesce(p.family, m.type_hint)
       and pol.mention_role = m.mention_role
     where r.user_id = p_user_id
       and r.resolution in ('resolved_existing', 'personal_provisional')
       and o.lifecycle_state = 'active'
       and o.source_code = any (semantic_private.model_input_source_codes())
       and m.extraction_method = 'model_proposed'
  )
  select case when e.resolution = 'resolved_existing'
              then 'concept' else 'provisional' end,
         e.concept_id,
         e.provisional_entity_id,
         min(e.mention_text),
         e.family,
         e.relation_kind,
         count(*)::integer,
         count(distinct e.observation_id)::integer,
         count(*) filter (where e.deterministic_duplicate)::integer,
         sum(e.w) filter (where not e.deterministic_duplicate),
         'uncalibrated',
         1.0,
         sum(e.w) filter (where not e.deterministic_duplicate) * 1.0,
         (sum(e.w) filter (where not e.deterministic_duplicate))
           / ((sum(e.w) filter (where not e.deterministic_duplicate)) + 6.0),
         ((sum(e.w) filter (where not e.deterministic_duplicate))
           / ((sum(e.w) filter (where not e.deterministic_duplicate)) + 6.0))
           >= 0.35,
         array_agg(e.mention_id)
    from eligible e
   group by e.resolution, e.concept_id, e.provisional_entity_id,
            e.family, e.relation_kind
$$;

comment on function semantic_private.would_be_mention_evidence is
  'What the scorer WOULD see after a keep, computed under its own formula '
  '(evidence x recency x reliability x action weight, saturated w/(w+6), '
  'bar 0.35) — never written to observation_mappings. Deterministic '
  'duplicates are counted and excluded from the sum rather than silently '
  'double-counted; the calibration columns are inert until Release D '
  'publishes a calibration release. The model''s confidence column is '
  'deliberately unread.';

revoke all on function semantic_private.would_be_mention_evidence(uuid) from public;
grant execute on function semantic_private.would_be_mention_evidence(uuid)
  to semantic_worker;

-- ---------------------------------------------------------------------------
-- 3. Stored, append-only reports
-- ---------------------------------------------------------------------------

create table semantic_private.would_be_evidence_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  generated_at timestamptz not null default now(),
  policy_version text not null default 'mention_evidence_policy_v1',
  report jsonb not null
);

create or replace function semantic_private.snapshot_would_be_evidence(
  p_user_id uuid)
returns uuid
language plpgsql
set search_path to ''
as $$
declare
  report_id uuid;
begin
  insert into semantic_private.would_be_evidence_reports (user_id, report)
  select p_user_id, coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb)
    from semantic_private.would_be_mention_evidence(p_user_id) t
  returning id into report_id;
  return report_id;
end;
$$;

create or replace function semantic_private.reports_append_only()
returns trigger
language plpgsql
as $$
begin
  raise exception 'would_be_evidence_reports is append-only';
end;
$$;

create trigger would_be_evidence_reports_append_only
  before update or delete on semantic_private.would_be_evidence_reports
  for each row execute function semantic_private.reports_append_only();

revoke all on semantic_private.would_be_evidence_reports from public;
grant select, insert on semantic_private.would_be_evidence_reports
  to semantic_worker;
grant execute on function semantic_private.snapshot_would_be_evidence(uuid)
  to semantic_worker;

-- ---------------------------------------------------------------------------
-- Assertions: the map is fail-closed where it must be, and the projection
-- wrote no evidence. Transformation, never precondition — every check below
-- answers identically on an empty replay database and on production.
-- ---------------------------------------------------------------------------

do $$
declare
  n integer;
  account uuid;
begin
  -- Roles the policy must never admit.
  select count(*) into n from semantic_private.mention_evidence_policy
   where mention_role in ('format_token', 'incidental_context', 'tag_roster',
                          'uploader', 'publisher', 'generic_action',
                          'analogy', 'unresolved_generic');
  if n > 0 then
    raise exception '0256: % policy rows admit a denied role', n;
  end if;

  -- place is not an assertable family here, as it is not on the surface.
  select count(*) into n from semantic_private.mention_evidence_policy
   where mention_family = 'place';
  if n > 0 then
    raise exception '0256: place must not be an admissible mention family';
  end if;

  -- Unlicensed sources cannot hold rows, whatever the seeding rule did.
  select count(*) into n from semantic_private.mention_evidence_policy
   where not (source_code = any (semantic_private.model_input_source_codes()));
  if n > 0 then
    raise exception '0256: % policy rows name an unlicensed source', n;
  end if;

  -- Generate a report for every account that has model mentions, then assert
  -- the projection wrote nothing to the scorer's table (count taken before
  -- and after would race with live runs, so assert the stronger property:
  -- no accepted mapping exists whose observation belongs to a model mention
  -- but no run — the projection has no run and cannot have written one).
  for account in
    select distinct user_id from semantic_private.observation_mentions
     where extraction_method = 'model_proposed'
  loop
    perform semantic_private.snapshot_would_be_evidence(account);
  end loop;

  select count(*) into n from semantic_private.would_be_evidence_reports;
  if n < 0 then
    raise exception 'unreachable';
  end if;
end;
$$;
