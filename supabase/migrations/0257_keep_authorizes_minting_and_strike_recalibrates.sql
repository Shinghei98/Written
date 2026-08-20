-- 0257 — Release C: keep authorizes minting, strike recalibrates, and no
-- decision is manufactured by arithmetic.
--
-- The review surface existed (`api.begin_calibration`, strike/restore/finish,
-- `review_events` with the full action vocabulary, `user_term_suppressions`).
-- What was missing is exactly what the revised memo names: keep and edit as
-- decisions that AUTHORIZE catalogue minting, an effective-decision
-- projection over the append-only events, and the recalibration apparatus in
-- dry-run form. This migration adds those and nothing downstream: no mint is
-- processed (Release D), no mapping is written, no assertion moves.
--
-- **Calibration parameters live in a versioned table for the dry-run.** The
-- memo houses them in the governed workbook/contract; that binding bites in
-- Release D when the scorer consumes a published calibration release, and
-- the workbook keys land there with the compile-time cross-check. Sequencing,
-- not shrinkage: the dry-run must run in SQL either way, and a
-- migration-seeded versioned table is the same governance the rest of
-- `semantic_private` uses (a superseding version takes new rows, never an
-- edit).
--
-- The α/β prior is 4/4 (prior mean 0.5 — no opinion), the minimum
-- distinct-user support reuses the EmergentTermMiner floor of five (the
-- repo's own number for "enough people to mean something"), and multipliers
-- are bounded [0.5, 1.5] so no stratum can be silenced or amplified into a
-- different product by feedback alone.

-- ---------------------------------------------------------------------------
-- 1. Mint requests: the object a keep or edit creates, and Release D consumes
-- ---------------------------------------------------------------------------

create table semantic_private.mint_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  review_item_id uuid not null,
  candidate_id uuid not null,
  provisional_entity_id uuid,
  concept_id uuid,
  requested_label text not null,
  requested_family text not null,
  origin text not null check (origin in ('keep', 'edit')),
  status text not null default 'pending'
    check (status in ('pending', 'completed', 'refused')),
  outcome jsonb,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  -- One request per review item, whatever is clicked how many times: the
  -- idempotency the memo demands is this key, not a convention.
  unique (review_item_id),
  foreign key (review_item_id, user_id)
    references semantic_private.review_items (id, user_id),
  foreign key (candidate_id, user_id)
    references semantic_private.user_term_candidates (id, user_id)
);

comment on table semantic_private.mint_requests is
  'Created only by an owner''s keep or edit through the api functions below; '
  'consumed only by Release D''s catalogue processor. Qwen never sees this '
  'table and cannot choose any identity recorded in it.';

-- Only the processor may move status, and only forward from pending.
create or replace function semantic_private.guard_mint_request_transition()
returns trigger
language plpgsql
as $$
begin
  if old.status <> 'pending' then
    raise exception 'mint request % is % and immutable', old.id, old.status;
  end if;
  if new.id <> old.id or new.user_id <> old.user_id
     or new.review_item_id <> old.review_item_id
     or new.requested_label <> old.requested_label
     or new.requested_family <> old.requested_family
     or new.origin <> old.origin then
    raise exception 'only status, outcome and completed_at may move on a mint request';
  end if;
  return new;
end;
$$;

create trigger mint_requests_forward_only
  before update on semantic_private.mint_requests
  for each row execute function semantic_private.guard_mint_request_transition();

create or replace function semantic_private.mint_requests_no_delete()
returns trigger
language plpgsql
as $$
begin
  raise exception 'mint requests are history; refuse one, never delete it';
end;
$$;

create trigger mint_requests_no_delete
  before delete on semantic_private.mint_requests
  for each row execute function semantic_private.mint_requests_no_delete();

revoke all on semantic_private.mint_requests from public;
grant select, insert, update on semantic_private.mint_requests to semantic_worker;

-- Edit decisions need somewhere to carry the corrected family; the events
-- table predates families being decidable.
alter table semantic_private.review_events add column corrected_family text;

-- ---------------------------------------------------------------------------
-- 2. keep and edit, beside the strike/restore/finish that already exist
-- ---------------------------------------------------------------------------

create or replace function api.keep_calibration_item(p_review_item_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  item record;
  newer integer;
  request_id uuid;
begin
  perform semantic_private.assert_surface_allowed('calibration');

  select ri.id, ri.user_id, ri.candidate_id, ri.review_epoch,
         c.provisional_entity_id, c.concept_id, c.lifecycle_state,
         coalesce(p.canonical_label, cl.label) as label,
         coalesce(p.family, cr.concept_kind) as family
    into item
    from semantic_private.review_items ri
    join semantic_private.user_term_candidates c
      on c.id = ri.candidate_id and c.user_id = ri.user_id
    left join semantic_private.provisional_entities p
      on p.id = c.provisional_entity_id
    left join ontology.concept_revisions cr
      on cr.concept_id = c.concept_id
     and cr.ontology_version_id = c.ontology_version_id
    left join lateral (
      select l.label from ontology.concept_labels l
       where l.concept_id = c.concept_id
         and l.ontology_version_id = c.ontology_version_id
       order by (l.kind = 'preferred') desc, l.label limit 1
    ) cl on true
   where ri.id = p_review_item_id
     and ri.user_id = auth.uid();
  if not found then
    raise exception 'review item not found' using errcode = 'P0002';
  end if;

  -- **A stale proposal revision cannot be decided.** A newer epoch's card for
  -- the same candidate supersedes this one; keeping the old card would record
  -- a decision against a question no longer being asked.
  select count(*) into newer
    from semantic_private.review_items later
   where later.user_id = item.user_id
     and later.candidate_id = item.candidate_id
     and later.review_epoch > item.review_epoch;
  if newer > 0 then
    raise exception 'a newer proposal revision exists; decide that one'
      using errcode = 'P0002';
  end if;

  insert into semantic_private.review_events
    (user_id, review_item_id, action, reason)
  values (item.user_id, p_review_item_id, 'keep', 'user_keep');

  insert into semantic_private.mint_requests
    (user_id, review_item_id, candidate_id, provisional_entity_id, concept_id,
     requested_label, requested_family, origin)
  values (item.user_id, p_review_item_id, item.candidate_id,
          item.provisional_entity_id, item.concept_id,
          item.label, item.family, 'keep')
  on conflict (review_item_id) do nothing;

  select id into request_id from semantic_private.mint_requests
   where review_item_id = p_review_item_id;

  return jsonb_build_object('kept', true, 'mint_request_id', request_id);
end;
$$;

create or replace function api.edit_calibration_item(
  p_review_item_id uuid, p_label text, p_family text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  item record;
  newer integer;
  request_id uuid;
begin
  perform semantic_private.assert_surface_allowed('calibration');

  if p_label is null or length(btrim(p_label)) = 0 or length(p_label) > 256 then
    raise exception 'a correction needs a label of 1..256 characters';
  end if;
  if p_family not in ('activity','album','anime','book','culture','event',
                      'franchise','game','group','idea','music_work',
                      'organization','person','sport','tour','work') then
    raise exception 'family % is not one a person may claim here', p_family;
  end if;

  select ri.id, ri.user_id, ri.candidate_id, ri.review_epoch,
         c.provisional_entity_id, c.concept_id
    into item
    from semantic_private.review_items ri
    join semantic_private.user_term_candidates c
      on c.id = ri.candidate_id and c.user_id = ri.user_id
   where ri.id = p_review_item_id
     and ri.user_id = auth.uid();
  if not found then
    raise exception 'review item not found' using errcode = 'P0002';
  end if;

  select count(*) into newer
    from semantic_private.review_items later
   where later.user_id = item.user_id
     and later.candidate_id = item.candidate_id
     and later.review_epoch > item.review_epoch;
  if newer > 0 then
    raise exception 'a newer proposal revision exists; decide that one'
      using errcode = 'P0002';
  end if;

  -- The original proposal is negative model feedback; the correction is the
  -- user's own words and is never counted as a Qwen success.
  insert into semantic_private.review_events
    (user_id, review_item_id, action, reason, corrected_label, corrected_family)
  values (item.user_id, p_review_item_id, 'edit', 'user_correction',
          btrim(p_label), p_family);

  insert into semantic_private.mint_requests
    (user_id, review_item_id, candidate_id, provisional_entity_id, concept_id,
     requested_label, requested_family, origin)
  values (item.user_id, p_review_item_id, item.candidate_id,
          item.provisional_entity_id, item.concept_id,
          btrim(p_label), p_family, 'edit')
  on conflict (review_item_id) do nothing;

  select id into request_id from semantic_private.mint_requests
   where review_item_id = p_review_item_id;

  return jsonb_build_object('edited', true, 'mint_request_id', request_id);
end;
$$;

revoke all on function api.keep_calibration_item(uuid) from public;
revoke all on function api.keep_calibration_item(uuid) from anon;
revoke all on function api.edit_calibration_item(uuid, text, text) from public;
revoke all on function api.edit_calibration_item(uuid, text, text) from anon;
grant execute on function api.keep_calibration_item(uuid) to authenticated;
grant execute on function api.edit_calibration_item(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Effective decisions and the enriched ledger, as views over append-only
--    rows: retention by construction, one current state per proposal
-- ---------------------------------------------------------------------------

create or replace view semantic_private.calibration_effective_decisions
with (security_invoker = on) as
select distinct on (e.review_item_id)
       e.review_item_id,
       e.user_id,
       e.action as effective_action,
       case e.action
         when 'keep' then 'positive'
         when 'edit' then 'negative'      -- against the model's proposal
         when 'strike_off' then 'negative'
         else 'pending'
       end as calibration_vote,
       e.created_at as decided_at,
       e.corrected_label,
       e.corrected_family
  from semantic_private.review_events e
 where e.action in ('keep', 'strike_off', 'edit', 'restore')
 order by e.review_item_id, e.created_at desc, e.id desc;

create or replace view semantic_private.calibration_feedback_ledger
with (security_invoker = on) as
select d.review_item_id,
       d.user_id,
       d.effective_action,
       d.calibration_vote,
       d.decided_at,
       ri.review_epoch,
       ri.model_revision,
       ri.prompt_version,
       ri.grammar_version,
       c.provisional_entity_id,
       c.concept_id,
       coalesce(p.family, m.type_hint) as mention_family,
       m.mention_role,
       o.source_code,
       o.action_type,
       'affinity_to' as relation_kind,
       o.id as independence_root
  from semantic_private.calibration_effective_decisions d
  join semantic_private.review_items ri
    on ri.id = d.review_item_id and ri.user_id = d.user_id
  join semantic_private.user_term_candidates c
    on c.id = ri.candidate_id and c.user_id = ri.user_id
  left join semantic_private.provisional_entities p
    on p.id = c.provisional_entity_id
  join semantic_private.candidate_support_links l
    on l.candidate_id = c.id
  join semantic_private.observations o
    on o.id = l.observation_id
  join semantic_private.observation_mentions m
    on m.observation_id = o.id and m.user_id = d.user_id;

-- ---------------------------------------------------------------------------
-- 4. Versioned calibration parameters and the dry-run report
-- ---------------------------------------------------------------------------

create table semantic_private.calibration_parameters (
  version text primary key,
  alpha numeric not null,
  beta numeric not null,
  min_distinct_users integer not null,
  min_multiplier numeric not null,
  max_multiplier numeric not null,
  backoff_order text[] not null
);

insert into semantic_private.calibration_parameters values
  ('calibration_v1', 4, 4, 5, 0.5, 1.5,
   array['source_code,action_type,mention_family,mention_role,relation_kind',
         'source_code,mention_family,mention_role',
         'mention_family,mention_role',
         'mention_role']);

revoke all on semantic_private.calibration_parameters from public;
grant select on semantic_private.calibration_parameters to semantic_worker;

create table semantic_private.calibration_dry_run_reports (
  id uuid primary key default gen_random_uuid(),
  generated_at timestamptz not null default now(),
  parameters_version text not null references
    semantic_private.calibration_parameters (version),
  decision_watermark timestamptz not null,
  report jsonb not null
);

create trigger calibration_dry_run_reports_append_only
  before update or delete on semantic_private.calibration_dry_run_reports
  for each row execute function semantic_private.reports_append_only();

revoke all on semantic_private.calibration_dry_run_reports from public;
grant select, insert on semantic_private.calibration_dry_run_reports
  to semantic_worker;

create or replace function semantic_private.calibration_dry_run(
  p_version text default 'calibration_v1')
returns uuid
language plpgsql
set search_path to ''
as $$
declare
  prm record;
  watermark timestamptz;
  report_id uuid;
begin
  select * into strict prm
    from semantic_private.calibration_parameters where version = p_version;

  select coalesce(max(decided_at), 'epoch'::timestamptz) into watermark
    from semantic_private.calibration_effective_decisions;

  insert into semantic_private.calibration_dry_run_reports
    (parameters_version, decision_watermark, report)
  select p_version, watermark, coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb)
    from (
      -- The exact stratum only for the dry run; hierarchical backoff is
      -- reported as which strata FAIL support, which is what Release D's
      -- published release resolves. One vote per (user, proposal revision,
      -- independence root), which the distinct below enforces.
      with votes as (
        select distinct l.user_id, l.review_item_id, l.independence_root,
               l.source_code, l.action_type, l.mention_family,
               l.mention_role, l.relation_kind, l.calibration_vote
          from semantic_private.calibration_feedback_ledger l
         where l.calibration_vote in ('positive', 'negative')
      )
      select v.source_code, v.action_type, v.mention_family, v.mention_role,
             v.relation_kind,
             count(*) filter (where v.calibration_vote = 'positive') as keeps,
             count(*) filter (where v.calibration_vote = 'negative') as strikes,
             count(distinct v.user_id) as distinct_users,
             prm.alpha / (prm.alpha + prm.beta) as prior_keep_rate,
             (count(*) filter (where v.calibration_vote = 'positive') + prm.alpha)
               / (count(*) + prm.alpha + prm.beta) as posterior_keep_rate,
             count(distinct v.user_id) >= prm.min_distinct_users as support_met,
             1.0 as current_multiplier,
             case when count(distinct v.user_id) >= prm.min_distinct_users
                  then least(greatest(
                         ((count(*) filter (where v.calibration_vote = 'positive') + prm.alpha)
                            / (count(*) + prm.alpha + prm.beta))
                           / (prm.alpha / (prm.alpha + prm.beta)),
                         prm.min_multiplier), prm.max_multiplier)
                  else 1.0 end as proposed_multiplier
        from votes v
       group by v.source_code, v.action_type, v.mention_family,
                v.mention_role, v.relation_kind
    ) s
  returning id into report_id;

  return report_id;
end;
$$;

grant execute on function semantic_private.calibration_dry_run(text)
  to semantic_worker;

-- ---------------------------------------------------------------------------
-- Assertions
-- ---------------------------------------------------------------------------

do $$
declare
  n integer;
begin
  -- anon holds nothing on the two new api functions (default privileges
  -- would otherwise grant them; revoke-by-name above is what this checks).
  select count(*) into n
    from information_schema.routine_privileges
   where routine_schema = 'api'
     and routine_name in ('keep_calibration_item', 'edit_calibration_item')
     and grantee = 'anon';
  if n > 0 then
    raise exception '0257: anon holds execute on a calibration decision';
  end if;

  -- No mint request exists yet: this migration authorizes, it does not decide.
  select count(*) into n from semantic_private.mint_requests;
  if n > 0 then
    raise exception '0257: a mint request appeared without a user decision';
  end if;

  -- The dry run runs and snapshots, even over zero decisions.
  perform semantic_private.calibration_dry_run();
  select count(*) into n from semantic_private.calibration_dry_run_reports;
  if n < 1 then
    raise exception '0257: the dry run produced no report';
  end if;
end;
$$;
