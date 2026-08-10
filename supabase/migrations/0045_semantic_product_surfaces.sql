-- Product surfaces: Memories, dyads, bios, icebreaker frames, and typed travel.
--
-- Adapted from the v0.3.1 package's `004_product_surfaces.sql`. The namespace rule and the
-- reason for it are in `0042_semantic_schema.sql`: the reference chain uses
-- `private` for its own objects and this app already owns that schema, so every
-- qualified reference here is `semantic_private`.
--
-- **Only schema references were translated.** Unlike 001 and 002, these files
-- use the word "private" in prose, in exception messages, and as a
-- `sensitivity` check-constraint *value*. Those are left exactly as written; a
-- blanket replace would have changed what the constraint accepts.
--
-- One further line moved: `grant usage on schema ontology, private to
-- service_role` at reference line 3460, which unadapted would have widened
-- access to the app's push secret and collaborator registry.
--
-- Ships no product behaviour. Nothing in Swift reads any of this.
--
-- Adapted against package v0.3.1, app commit b3e19ae, migration head 0043.

-- Written ontology/product surfaces v0.2.
-- Apply after 001_schema.sql, 002_rls_and_rpc.sql, and 003_seed.sql.
--
-- This migration remains server-internal. It deliberately adds no cross-user
-- Data API RPC. Discovery/bio/icebreaker reads must be introduced later as
-- narrowly scoped, match-aware security-definer functions.
begin;

-- -------------------------------------------------------------------------
-- Source-policy parity with the deterministic v0.2 adapters. These weights
-- describe sanitized semantic observations, not raw provider rows. Calendar
-- receives its high-signal weights only after the mapping guard below proves
-- an eligible allowlist-first classifier result.
-- -------------------------------------------------------------------------

update semantic_private.sources as source
set default_reliability = policy.default_reliability,
    action_weights = policy.action_weights
from (values
  ('apple_music', 0.90::double precision,
   '{"library_song":0.48,"library_album":0.55,"library_artist":0.45,"library_playlist":0.60,"playlist_item":0.70,"rating":0.88,"recently_added":0.55,"recently_played":0.78,"saved_track":0.60,"saved_album":0.55,"followed_artist":0.55,"recommendation":0.0}'::jsonb),
  ('music_library', 0.75::double precision,
   '{"library_song":0.48}'::jsonb),
  ('spotify', 0.90::double precision,
   '{"followed_artist":0.55,"recently_played":0.78,"saved_album":0.55,"saved_track":0.60,"saved":0.0,"playlist_item":0.0}'::jsonb),
  ('youtube', 0.80::double precision,
   '{"subscription":0.55,"video":0.65,"watched":0.72,"liked":0.90,"liked_video":0.90,"shared":0.92,"playlist":0.0,"playlist_item":0.0}'::jsonb),
  ('apple_calendar', 0.90::double precision,
   '{"scheduled":0.90,"booked":0.0,"entered_by_user":0.0,"cancelled":0.0}'::jsonb),
  ('google_calendar', 0.90::double precision,
   '{"scheduled":0.90,"booked":0.0,"entered_by_user":0.0,"cancelled":0.0}'::jsonb),
  ('apple_podcasts', 0.80::double precision,
   '{"followed":0.70,"played":0.75,"saved":0.82}'::jsonb),
  ('podcast', 0.80::double precision,
   '{"show":0.0,"episode":0.0,"followed":0.70,"played":0.75,"saved":0.82}'::jsonb)
) as policy(source_code, default_reliability, action_weights)
where source.source_code = policy.source_code;

-- -------------------------------------------------------------------------
-- Reusable payload firewall. Surface and derivation JSON is intentionally a
-- small, handler-built projection. The recursive key denylist catches nested
-- raw Calendar/itinerary aliases, while a table-specific root allowlist keeps
-- arbitrary vendor payloads out of presentation storage.
-- -------------------------------------------------------------------------

create or replace function semantic_private.jsonb_tree_has_no_private_keys(
  payload jsonb,
  depth integer default 0
)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  item record;
  normalized_key text;
begin
  if payload is null or depth > 12 then return false; end if;
  if jsonb_typeof(payload) = 'object' then
    for item in select key, value from jsonb_each(payload) loop
      normalized_key := lower(regexp_replace(item.key, '[^a-z0-9]+', '_', 'g'));
      if normalized_key = any (array[
        'raw', 'raw_observation', 'raw_calendar', 'raw_event',
        'event_text', 'calendar_text', 'title', 'description', 'detail',
        'notes', 'route', 'itinerary', 'ticket', 'flight_number',
        'carrier_code', 'origin_code', 'destination_code', 'departure_at',
        'arrival_at', 'start_at', 'end_at', 'start_time', 'end_time',
        'exact_date', 'booking_code', 'booking_reference', 'reservation_id',
        'confirmation_code', 'hotel', 'hotel_name', 'organizer', 'attendee',
        'contact', 'email', 'phone', 'meeting_url', 'source_url',
        'observation_id', 'source_observation_id'
      ]::text[]) then
        return false;
      end if;
      if not semantic_private.jsonb_tree_has_no_private_keys(item.value, depth + 1) then
        return false;
      end if;
    end loop;
  elsif jsonb_typeof(payload) = 'array' then
    for item in select value from jsonb_array_elements(payload) loop
      if not semantic_private.jsonb_tree_has_no_private_keys(item.value, depth + 1) then
        return false;
      end if;
    end loop;
  elsif jsonb_typeof(payload) = 'string'
        and char_length(payload #>> '{}') > 2048 then
    return false;
  end if;
  return true;
end;
$$;

create or replace function semantic_private.jsonb_payload_is_safe(
  payload jsonb,
  maximum_bytes integer,
  allowed_root_keys text[]
)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
begin
  if payload is null
     or jsonb_typeof(payload) <> 'object'
     or maximum_bytes < 2
     or octet_length(payload::text) > maximum_bytes
     or not semantic_private.jsonb_tree_has_no_private_keys(payload, 0) then
    return false;
  end if;
  if allowed_root_keys is not null and exists (
    select 1 from jsonb_object_keys(payload) as root_key
    where root_key <> all (allowed_root_keys)
  ) then
    return false;
  end if;
  return true;
end;
$$;

-- -------------------------------------------------------------------------
-- Score semantics: preserve legacy confidence while separating agreement
-- from evidence quality. A compatibility trigger fills both new values from
-- confidence for legacy writers; v0.2 writers should always set them.
-- -------------------------------------------------------------------------

alter table semantic_private.concept_source_scores
  add column if not exists mapping_agreement double precision,
  add column if not exists evidence_quality double precision;
alter table semantic_private.concept_scores
  add column if not exists mapping_agreement double precision,
  add column if not exists evidence_quality double precision;
alter table semantic_private.motif_instances
  add column if not exists mapping_agreement double precision,
  add column if not exists evidence_quality double precision;
alter table semantic_private.assertion_score_versions
  add column if not exists mapping_agreement double precision,
  add column if not exists evidence_quality double precision;

-- Evidence weight is relation-specific. In particular, one liked YouTube
-- video may strongly support its content topic while only weakly supporting
-- the uploader/represented creator. Defaults preserve legacy writers.
alter table semantic_private.observation_mentions
  add column if not exists evidence_weight double precision not null default 1.0;
alter table semantic_private.observation_mappings
  add column if not exists evidence_weight double precision not null default 1.0;
alter table semantic_private.observation_mappings
  add column if not exists cross_source_fusion_allowed boolean not null
    default true;
alter table semantic_private.observation_mappings
  add column if not exists youtube_semantic_kind text;
alter table semantic_private.observation_mentions
  drop constraint if exists observation_mentions_evidence_weight_v02_check,
  add constraint observation_mentions_evidence_weight_v02_check
    check (evidence_weight between 0 and 1);
alter table semantic_private.observation_mappings
  drop constraint if exists observation_mappings_evidence_weight_v02_check,
  drop constraint if exists observation_mappings_youtube_semantic_v02_check,
  add constraint observation_mappings_evidence_weight_v02_check
    check (evidence_weight between 0 and 1),
  add constraint observation_mappings_youtube_semantic_v02_check check (
    youtube_semantic_kind is null or youtube_semantic_kind in (
      'provider_topic', 'channel_identity', 'channel_role',
      'uploader_tag', 'written_title_tag'
    )
  );

-- Recency is a versioned evidence attribute, not one global half-life. The
-- policy and rule keys identify a domain/source/action-specific curve (for
-- example a short video-like curve or a longer travel/event curve), and as_of
-- makes replay deterministic. Temporal weight and missing-timestamp quality
-- remain separate so an unknown date is neither silently fresh nor discarded.
-- Legacy defaults mean identity/no-decay only for old writers.
alter table semantic_private.observation_mentions
  add column if not exists recency_weight double precision not null default 1.0,
  add column if not exists recency_quality double precision not null default 1.0,
  add column if not exists recency_policy_version text not null
    default 'legacy-unversioned',
  add column if not exists recency_rule_id text not null
    default 'legacy.static',
  add column if not exists recency_status text not null
    default 'not_recorded',
  add column if not exists recency_timestamp_quality text not null
    default 'not_recorded',
  add column if not exists recency_as_of timestamptz not null default now();
alter table semantic_private.observation_mappings
  add column if not exists recency_weight double precision not null default 1.0,
  add column if not exists recency_quality double precision not null default 1.0,
  add column if not exists recency_policy_version text not null
    default 'legacy-unversioned',
  add column if not exists recency_rule_id text not null
    default 'legacy.static',
  add column if not exists recency_status text not null
    default 'not_recorded',
  add column if not exists recency_timestamp_quality text not null
    default 'not_recorded',
  add column if not exists recency_as_of timestamptz not null default now();
alter table semantic_private.concept_source_scores
  add column if not exists recency_policy_version text not null
    default 'legacy-unversioned',
  add column if not exists recency_as_of timestamptz not null default now();
alter table semantic_private.concept_scores
  add column if not exists recency_policy_version text not null
    default 'legacy-unversioned',
  add column if not exists recency_as_of timestamptz not null default now();
alter table semantic_private.motif_instances
  add column if not exists recency_policy_version text not null
    default 'legacy-unversioned',
  add column if not exists recency_as_of timestamptz not null default now();
alter table semantic_private.assertion_score_versions
  add column if not exists recency_policy_version text not null
    default 'legacy-unversioned',
  add column if not exists recency_as_of timestamptz not null default now();
alter table semantic_private.motif_support
  add column if not exists recency_weight double precision not null default 1.0,
  add column if not exists recency_quality double precision not null default 1.0,
  add column if not exists recency_policy_version text not null
    default 'legacy-unversioned',
  add column if not exists recency_rule_id text not null
    default 'legacy.static',
  add column if not exists recency_status text not null
    default 'not_recorded',
  add column if not exists recency_timestamp_quality text not null
    default 'not_recorded',
  add column if not exists recency_as_of timestamptz not null default now();
alter table semantic_private.assertion_evidence
  add column if not exists recency_weight double precision not null default 1.0,
  add column if not exists recency_quality double precision not null default 1.0,
  add column if not exists recency_policy_version text not null
    default 'legacy-unversioned',
  add column if not exists recency_rule_id text not null
    default 'legacy.static',
  add column if not exists recency_status text not null
    default 'not_recorded',
  add column if not exists recency_timestamp_quality text not null
    default 'not_recorded',
  add column if not exists recency_as_of timestamptz not null default now();

create or replace function semantic_private.recency_audit_is_valid(
  recency_weight_value double precision,
  recency_quality_value double precision,
  policy_version_value text,
  rule_id_value text,
  status_value text,
  timestamp_quality_value text
)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select
    recency_weight_value between 0 and 1
    and recency_quality_value > 0 and recency_quality_value <= 1
    and char_length(policy_version_value) between 3 and 120
    and policy_version_value ~ '^[a-z0-9][a-z0-9._:-]+$'
    and char_length(rule_id_value) between 3 and 128
    and rule_id_value ~ '^[a-z0-9][a-z0-9._:-]+$'
    and status_value in (
      'not_recorded', 'unknown_timestamp', 'recent', 'decaying',
      'future_clock_skew', 'future_outside_anticipation_window',
      'future_anticipation', 'event_current', 'post_event_decay', 'expired'
    )
    and timestamp_quality_value in ('not_recorded', 'known', 'unknown')
    and (
      (status_value = 'not_recorded'
       and timestamp_quality_value = 'not_recorded')
      or (status_value = 'unknown_timestamp'
          and timestamp_quality_value = 'unknown'
          and recency_quality_value < 1)
      or (status_value not in ('not_recorded', 'unknown_timestamp')
          and timestamp_quality_value = 'known')
    );
$$;

alter table semantic_private.observation_mentions
  drop constraint if exists observation_mentions_recency_v02_check,
  add constraint observation_mentions_recency_v02_check check (
    semantic_private.recency_audit_is_valid(
      recency_weight, recency_quality, recency_policy_version,
      recency_rule_id, recency_status, recency_timestamp_quality
    )
  );
alter table semantic_private.observation_mappings
  drop constraint if exists observation_mappings_recency_v02_check,
  add constraint observation_mappings_recency_v02_check check (
    semantic_private.recency_audit_is_valid(
      recency_weight, recency_quality, recency_policy_version,
      recency_rule_id, recency_status, recency_timestamp_quality
    )
  );
alter table semantic_private.motif_support
  drop constraint if exists motif_support_recency_v02_check,
  add constraint motif_support_recency_v02_check check (
    semantic_private.recency_audit_is_valid(
      recency_weight, recency_quality, recency_policy_version,
      recency_rule_id, recency_status, recency_timestamp_quality
    )
  );
alter table semantic_private.assertion_evidence
  drop constraint if exists assertion_evidence_recency_v02_check,
  add constraint assertion_evidence_recency_v02_check check (
    semantic_private.recency_audit_is_valid(
      recency_weight, recency_quality, recency_policy_version,
      recency_rule_id, recency_status, recency_timestamp_quality
    )
  );
alter table semantic_private.concept_source_scores
  drop constraint if exists concept_source_scores_recency_v02_check,
  add constraint concept_source_scores_recency_v02_check check (
    char_length(recency_policy_version) between 3 and 120
    and recency_policy_version ~ '^[a-z0-9][a-z0-9._:-]+$'
  );
alter table semantic_private.concept_scores
  drop constraint if exists concept_scores_recency_v02_check,
  add constraint concept_scores_recency_v02_check check (
    char_length(recency_policy_version) between 3 and 120
    and recency_policy_version ~ '^[a-z0-9][a-z0-9._:-]+$'
  );
alter table semantic_private.motif_instances
  drop constraint if exists motif_instances_recency_v02_check,
  add constraint motif_instances_recency_v02_check check (
    char_length(recency_policy_version) between 3 and 120
    and recency_policy_version ~ '^[a-z0-9][a-z0-9._:-]+$'
  );
alter table semantic_private.assertion_score_versions
  drop constraint if exists assertion_scores_recency_v02_check,
  add constraint assertion_scores_recency_v02_check check (
    char_length(recency_policy_version) between 3 and 120
    and recency_policy_version ~ '^[a-z0-9][a-z0-9._:-]+$'
  );

-- A semantic run owns one recency clock. Mapping and aggregate rows cannot
-- drift by taking their own now(); linked motif/assertion evidence inherits
-- the complete audit tuple from its observation mapping.
update semantic_private.observation_mappings as target
set recency_as_of = run.started_at
from semantic_private.semantic_runs as run
where run.id = target.semantic_run_id
  and run.user_id = target.user_id
  and target.recency_as_of is distinct from run.started_at;
update semantic_private.concept_source_scores as target
set recency_as_of = run.started_at
from semantic_private.semantic_runs as run
where run.id = target.semantic_run_id
  and run.user_id = target.user_id
  and target.recency_as_of is distinct from run.started_at;
update semantic_private.concept_scores as target
set recency_as_of = run.started_at
from semantic_private.semantic_runs as run
where run.id = target.semantic_run_id
  and run.user_id = target.user_id
  and target.recency_as_of is distinct from run.started_at;
update semantic_private.motif_instances as target
set recency_as_of = run.started_at
from semantic_private.semantic_runs as run
where run.id = target.semantic_run_id
  and run.user_id = target.user_id
  and target.recency_as_of is distinct from run.started_at;
update semantic_private.assertion_score_versions as target
set recency_as_of = run.started_at
from semantic_private.semantic_runs as run
where run.id = target.semantic_run_id
  and run.user_id = target.user_id
  and target.recency_as_of is distinct from run.started_at;
update semantic_private.motif_support as target
set recency_weight = mapping.recency_weight,
    recency_quality = mapping.recency_quality,
    recency_policy_version = mapping.recency_policy_version,
    recency_rule_id = mapping.recency_rule_id,
    recency_status = mapping.recency_status,
    recency_timestamp_quality = mapping.recency_timestamp_quality,
    recency_as_of = mapping.recency_as_of
from semantic_private.observation_mappings as mapping
where mapping.id = target.observation_mapping_id
  and mapping.user_id = target.user_id
  and mapping.semantic_run_id = target.semantic_run_id
  and (
    target.recency_weight,
    target.recency_quality,
    target.recency_policy_version,
    target.recency_rule_id,
    target.recency_status,
    target.recency_timestamp_quality,
    target.recency_as_of
  ) is distinct from (
    mapping.recency_weight,
    mapping.recency_quality,
    mapping.recency_policy_version,
    mapping.recency_rule_id,
    mapping.recency_status,
    mapping.recency_timestamp_quality,
    mapping.recency_as_of
  );
update semantic_private.assertion_evidence as target
set recency_weight = mapping.recency_weight,
    recency_quality = mapping.recency_quality,
    recency_policy_version = mapping.recency_policy_version,
    recency_rule_id = mapping.recency_rule_id,
    recency_status = mapping.recency_status,
    recency_timestamp_quality = mapping.recency_timestamp_quality,
    recency_as_of = mapping.recency_as_of
from semantic_private.observation_mappings as mapping
where mapping.id = target.observation_mapping_id
  and mapping.user_id = target.user_id
  and (
    target.recency_weight,
    target.recency_quality,
    target.recency_policy_version,
    target.recency_rule_id,
    target.recency_status,
    target.recency_timestamp_quality,
    target.recency_as_of
  ) is distinct from (
    mapping.recency_weight,
    mapping.recency_quality,
    mapping.recency_policy_version,
    mapping.recency_rule_id,
    mapping.recency_status,
    mapping.recency_timestamp_quality,
    mapping.recency_as_of
  );

alter table semantic_private.observation_mappings
  alter column recency_as_of drop default;
alter table semantic_private.concept_source_scores
  alter column recency_as_of drop default;
alter table semantic_private.concept_scores
  alter column recency_as_of drop default;
alter table semantic_private.motif_instances
  alter column recency_as_of drop default;
alter table semantic_private.assertion_score_versions
  alter column recency_as_of drop default;
alter table semantic_private.motif_support
  alter column recency_as_of drop default;
alter table semantic_private.assertion_evidence
  alter column recency_as_of drop default;

create or replace function semantic_private.pin_recency_to_semantic_run()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  pinned_as_of timestamptz;
begin
  select run.started_at
  into pinned_as_of
  from semantic_private.semantic_runs as run
  where run.id = new.semantic_run_id and run.user_id = new.user_id;
  if not found then
    raise exception using
      errcode = '23503',
      message = 'recency row must reference an existing semantic run';
  end if;
  if new.recency_as_of is null then
    new.recency_as_of := pinned_as_of;
  elsif new.recency_as_of is distinct from pinned_as_of then
    raise exception using
      errcode = '23514',
      message = 'recency_as_of must equal semantic run started_at';
  end if;
  return new;
end;
$$;

drop trigger if exists observation_mappings_pin_run_recency
  on semantic_private.observation_mappings;
create trigger observation_mappings_pin_run_recency
before insert or update of semantic_run_id, user_id, recency_as_of
on semantic_private.observation_mappings
for each row execute function semantic_private.pin_recency_to_semantic_run();

drop trigger if exists concept_source_scores_pin_run_recency
  on semantic_private.concept_source_scores;
create trigger concept_source_scores_pin_run_recency
before insert or update of semantic_run_id, user_id, recency_as_of
on semantic_private.concept_source_scores
for each row execute function semantic_private.pin_recency_to_semantic_run();

drop trigger if exists concept_scores_pin_run_recency
  on semantic_private.concept_scores;
create trigger concept_scores_pin_run_recency
before insert or update of semantic_run_id, user_id, recency_as_of
on semantic_private.concept_scores
for each row execute function semantic_private.pin_recency_to_semantic_run();

drop trigger if exists motif_instances_pin_run_recency
  on semantic_private.motif_instances;
create trigger motif_instances_pin_run_recency
before insert or update of semantic_run_id, user_id, recency_as_of
on semantic_private.motif_instances
for each row execute function semantic_private.pin_recency_to_semantic_run();

drop trigger if exists assertion_scores_pin_run_recency
  on semantic_private.assertion_score_versions;
create trigger assertion_scores_pin_run_recency
before insert or update of semantic_run_id, user_id, recency_as_of
on semantic_private.assertion_score_versions
for each row execute function semantic_private.pin_recency_to_semantic_run();

create or replace function semantic_private.inherit_mapping_recency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  mapping_row semantic_private.observation_mappings%rowtype;
begin
  select mapping.*
  into mapping_row
  from semantic_private.observation_mappings as mapping
  where mapping.id = new.observation_mapping_id
    and mapping.user_id = new.user_id
    and (
      tg_table_name <> 'motif_support'
      or mapping.semantic_run_id = new.semantic_run_id
    );
  if not found then
    raise exception using
      errcode = '23503',
      message = 'linked recency row must reference an existing mapping';
  end if;
  new.recency_weight := mapping_row.recency_weight;
  new.recency_quality := mapping_row.recency_quality;
  new.recency_policy_version := mapping_row.recency_policy_version;
  new.recency_rule_id := mapping_row.recency_rule_id;
  new.recency_status := mapping_row.recency_status;
  new.recency_timestamp_quality := mapping_row.recency_timestamp_quality;
  new.recency_as_of := mapping_row.recency_as_of;
  return new;
end;
$$;

drop trigger if exists motif_support_inherit_mapping_recency
  on semantic_private.motif_support;
create trigger motif_support_inherit_mapping_recency
before insert or update on semantic_private.motif_support
for each row execute function semantic_private.inherit_mapping_recency();

drop trigger if exists assertion_evidence_inherit_mapping_recency
  on semantic_private.assertion_evidence;
create trigger assertion_evidence_inherit_mapping_recency
before insert or update on semantic_private.assertion_evidence
for each row execute function semantic_private.inherit_mapping_recency();

update semantic_private.concept_source_scores
set mapping_agreement = coalesce(mapping_agreement, confidence),
    evidence_quality = coalesce(evidence_quality, confidence)
where mapping_agreement is null or evidence_quality is null;
update semantic_private.concept_scores
set mapping_agreement = coalesce(mapping_agreement, confidence),
    evidence_quality = coalesce(evidence_quality, confidence)
where mapping_agreement is null or evidence_quality is null;
update semantic_private.motif_instances
set mapping_agreement = coalesce(mapping_agreement, confidence),
    evidence_quality = coalesce(evidence_quality, confidence)
where mapping_agreement is null or evidence_quality is null;
update semantic_private.assertion_score_versions
set mapping_agreement = coalesce(mapping_agreement, confidence),
    evidence_quality = coalesce(evidence_quality, confidence)
where mapping_agreement is null or evidence_quality is null;

create or replace function semantic_private.fill_score_quality_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.mapping_agreement := coalesce(new.mapping_agreement, new.confidence);
  new.evidence_quality := coalesce(new.evidence_quality, new.confidence);
  return new;
end;
$$;

drop trigger if exists concept_source_scores_fill_quality
  on semantic_private.concept_source_scores;
create trigger concept_source_scores_fill_quality
before insert or update of confidence, mapping_agreement, evidence_quality
on semantic_private.concept_source_scores
for each row execute function semantic_private.fill_score_quality_columns();

drop trigger if exists concept_scores_fill_quality on semantic_private.concept_scores;
create trigger concept_scores_fill_quality
before insert or update of confidence, mapping_agreement, evidence_quality
on semantic_private.concept_scores
for each row execute function semantic_private.fill_score_quality_columns();

drop trigger if exists motif_instances_fill_quality on semantic_private.motif_instances;
create trigger motif_instances_fill_quality
before insert or update of confidence, mapping_agreement, evidence_quality
on semantic_private.motif_instances
for each row execute function semantic_private.fill_score_quality_columns();

drop trigger if exists assertion_score_versions_fill_quality
  on semantic_private.assertion_score_versions;
create trigger assertion_score_versions_fill_quality
before insert or update of confidence, mapping_agreement, evidence_quality
on semantic_private.assertion_score_versions
for each row execute function semantic_private.fill_score_quality_columns();

alter table semantic_private.concept_source_scores
  alter column mapping_agreement set not null,
  alter column evidence_quality set not null;
alter table semantic_private.concept_scores
  alter column mapping_agreement set not null,
  alter column evidence_quality set not null;
alter table semantic_private.motif_instances
  alter column mapping_agreement set not null,
  alter column evidence_quality set not null;
alter table semantic_private.assertion_score_versions
  alter column mapping_agreement set not null,
  alter column evidence_quality set not null;

alter table semantic_private.concept_source_scores
  drop constraint if exists concept_source_scores_mapping_agreement_v02_check,
  drop constraint if exists concept_source_scores_evidence_quality_v02_check,
  add constraint concept_source_scores_mapping_agreement_v02_check
    check (mapping_agreement between 0 and 1),
  add constraint concept_source_scores_evidence_quality_v02_check
    check (evidence_quality between 0 and 1);
alter table semantic_private.concept_scores
  drop constraint if exists concept_scores_mapping_agreement_v02_check,
  drop constraint if exists concept_scores_evidence_quality_v02_check,
  add constraint concept_scores_mapping_agreement_v02_check
    check (mapping_agreement between 0 and 1),
  add constraint concept_scores_evidence_quality_v02_check
    check (evidence_quality between 0 and 1);
alter table semantic_private.motif_instances
  drop constraint if exists motif_instances_mapping_agreement_v02_check,
  drop constraint if exists motif_instances_evidence_quality_v02_check,
  add constraint motif_instances_mapping_agreement_v02_check
    check (mapping_agreement between 0 and 1),
  add constraint motif_instances_evidence_quality_v02_check
    check (evidence_quality between 0 and 1);
alter table semantic_private.assertion_score_versions
  drop constraint if exists assertion_scores_mapping_agreement_v02_check,
  drop constraint if exists assertion_scores_evidence_quality_v02_check,
  add constraint assertion_scores_mapping_agreement_v02_check
    check (mapping_agreement between 0 and 1),
  add constraint assertion_scores_evidence_quality_v02_check
    check (evidence_quality between 0 and 1);

-- -------------------------------------------------------------------------
-- Versioned worker/model roles and typed predicates used by product surfaces.
-- -------------------------------------------------------------------------

alter table ontology.model_versions
  drop constraint if exists model_versions_model_role_check,
  drop constraint if exists model_versions_model_role_v02_check,
  add constraint model_versions_model_role_v02_check check (model_role in (
    'extractor', 'resolver', 'scorer', 'surfacing', 'term_miner',
    'calendar_classifier', 'youtube_resolver', 'memories_builder',
    'dyad_ranker', 'bio_renderer', 'icebreaker_renderer'
  ));

insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values
  (ontology.stable_uuid('written:model:calendar-classifier:v0.2.0'),
   'calendar_privacy_travel_classifier', '0.2.0', 'calendar_classifier', null,
   '{"default":"exclude_unless_allowlisted","raw_text_egress":false}'::jsonb,
   'active'),
  (ontology.stable_uuid('written:model:youtube-resolver:v0.2.0'),
   'youtube_channel_role_resolver', '0.2.0', 'youtube_resolver', null,
   '{"stable_key":"youtube_channel_id","fuzzy_creator_merge":false}'::jsonb,
   'active'),
  (ontology.stable_uuid('written:model:memories-builder:v0.2.0'),
   'memories_multiresolution_builder', '0.2.0', 'memories_builder', null,
   '{"mass_conservation":true,"user_terms_preserved":true}'::jsonb, 'active'),
  (ontology.stable_uuid('written:model:dyad-ranker:v0.2.0'),
   'typed_graph_dyad_ranker', '0.2.0', 'dyad_ranker', null,
   '{"directional":true,"missing_reduces_comparability_only":true}'::jsonb,
   'active'),
  (ontology.stable_uuid('written:model:bio-renderer:v0.2.0'),
   'validated_fact_bio_renderer', '0.2.0', 'bio_renderer', null,
   '{"maximum_personalized_clauses":1}'::jsonb, 'active'),
  (ontology.stable_uuid('written:model:icebreaker-renderer:v0.2.0'),
   'deterministic_icebreaker_renderer', '0.2.0', 'icebreaker_renderer', null,
   '{"raw_evidence_input":false,"deterministic_templates":true}'::jsonb,
   'active')
on conflict (model_key, version) do nothing;

insert into ontology.relation_types (
  predicate_key, relation_class, inverse_predicate_key, is_symmetric,
  transitive_for_inference, max_inference_hops, assertion_safe, description
) values
  ('channel_represents', 'descriptive', null, false, false, 0, false,
   'Exact reviewed provider-channel identity link only.'),
  ('content_by', 'descriptive', null, false, false, 1, true,
   'Content was authored or uploaded by a resolved creator.'),
  ('content_about', 'descriptive', null, false, false, 1, true,
   'Content is about an entity; not evidence that uploader represents it.'),
  ('features', 'descriptive', null, false, false, 1, true,
   'Content features an entity without claiming authorship.'),
  ('scheduled_travel_to', 'observed_action', null, false, false, 0, false,
   'A private calendar itinerary scheduled travel; not completed travel.'),
  ('booked_activity_at', 'observed_action', null, false, false, 0, false,
   'A private commercial artifact booked an activity; not attendance or liking.'),
  ('booked_event', 'observed_action', null, false, false, 0, false,
   'A private commercial artifact booked an event; not attendance or liking.'),
  ('scheduled_dining', 'observed_action', null, false, false, 0, false,
   'A private reservation scheduled dining; not attendance or preference.'),
  ('explicit_association_with', 'user_claim', null, false, false, 0, false,
   'Neutral explicit association selected by the user.'),
  ('likes', 'user_claim', null, false, false, 0, false,
   'Strong liking wording requiring user addition or confirmation.'),
  ('visited', 'user_claim', null, false, false, 0, false,
   'Completed travel requiring user addition or confirmation.'),
  ('travel_interest', 'user_claim', null, false, false, 0, true,
   'Reviewable travel interest; never entailed by a booking alone.'),
  ('wants_to_visit', 'user_claim', null, false, false, 0, false,
   'Explicit future travel intention.'),
  ('returns_to', 'user_claim', null, false, false, 0, false,
   'Recurring travel wording requiring explicit confirmation.'),
  ('attended_activity_at', 'user_claim', null, false, false, 0, false,
   'Completed attendance requiring user addition or confirmation.'),
  ('likes_activity', 'user_claim', null, false, false, 0, false,
   'Activity preference requiring user addition or confirmation.'),
  ('recurring_presence_at', 'user_claim', null, false, false, 0, true,
   'Reviewable recurring-place candidate; not hometown or residence.'),
  ('home_base_candidate', 'user_claim', null, false, false, 0, false,
   'Private review candidate requiring explicit confirmation.'),
  ('hometown', 'user_claim', null, false, false, 0, false,
   'Explicit self-report only; never machine inferred.'),
  ('lives_in', 'user_claim', null, false, false, 0, false,
   'Explicit self-report only; never machine inferred.')
on conflict (predicate_key) do update set
  relation_class = excluded.relation_class,
  inverse_predicate_key = excluded.inverse_predicate_key,
  is_symmetric = excluded.is_symmetric,
  transitive_for_inference = excluded.transitive_for_inference,
  max_inference_hops = excluded.max_inference_hops,
  assertion_safe = excluded.assertion_safe,
  description = excluded.description;

alter table semantic_private.worker_jobs
  drop constraint if exists worker_jobs_job_type_check,
  drop constraint if exists worker_jobs_job_type_v02_check,
  add constraint worker_jobs_job_type_v02_check check (job_type in (
    'map_observation', 'recompute_user', 'mine_terms',
    'refresh_external_entity', 'classify_calendar',
    'resolve_youtube_channel', 'build_memories', 'compute_dyad',
    'render_bio', 'render_icebreaker'
  ));

-- -------------------------------------------------------------------------
-- Per-run YouTube policy is default-deny and tied to a reviewed approval.
-- A process boolean cannot enable channel/entity transfer, fusion, or a
-- surface. Revocation is checked dynamically by every policy consumer.
-- -------------------------------------------------------------------------

create table if not exists ontology.youtube_policy_approvals (
  id uuid primary key default extensions.gen_random_uuid(),
  approval_reference text not null unique,
  approval_version text not null,
  approval_state text not null default 'approved',
  allow_channel_identity boolean not null default false,
  allow_role_resolution boolean not null default false,
  allow_uploader_tags boolean not null default false,
  allow_title_tags boolean not null default false,
  allow_cross_source_fusion boolean not null default false,
  allow_bio boolean not null default false,
  allow_icebreaker boolean not null default false,
  allow_explanation boolean not null default false,
  approved_at timestamptz not null,
  expires_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  constraint youtube_policy_approvals_reference_check check (
    char_length(approval_reference) between 8 and 240
    and approval_reference ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]+$'
  ),
  constraint youtube_policy_approvals_version_check check (
    char_length(approval_version) between 1 and 80
  ),
  constraint youtube_policy_approvals_state_check check (
    approval_state in ('approved', 'revoked', 'expired')
  ),
  constraint youtube_policy_approvals_state_time_check check (
    (approval_state = 'approved' and revoked_at is null) or
    (approval_state <> 'approved' and revoked_at is not null)
  ),
  constraint youtube_policy_approvals_window_check check (
    expires_at is null or expires_at > approved_at
  ),
  constraint youtube_policy_approvals_nonempty_scope_check check (
    allow_channel_identity or allow_role_resolution or allow_uploader_tags
    or allow_title_tags or allow_cross_source_fusion or allow_bio
    or allow_icebreaker or allow_explanation
  ),
  constraint youtube_policy_approvals_surface_scope_check check (
    (not allow_bio or allow_cross_source_fusion)
    and (not allow_icebreaker or allow_cross_source_fusion)
    and (not allow_explanation or (allow_bio or allow_icebreaker))
  )
);

create table if not exists semantic_private.youtube_run_policies (
  semantic_run_id uuid primary key,
  user_id uuid not null,
  ontology_version_id uuid not null,
  youtube_resolver_model_id uuid
    references ontology.model_versions(id) on delete restrict,
  approval_id uuid
    references ontology.youtube_policy_approvals(id) on delete restrict,
  policy_version text not null default 'deny-all-v1',
  allow_channel_identity boolean not null default false,
  allow_role_resolution boolean not null default false,
  allow_uploader_tags boolean not null default false,
  allow_title_tags boolean not null default false,
  allow_cross_source_fusion boolean not null default false,
  allow_bio boolean not null default false,
  allow_icebreaker boolean not null default false,
  allow_explanation boolean not null default false,
  created_at timestamptz not null default now(),
  unique (semantic_run_id, user_id, ontology_version_id),
  foreign key (semantic_run_id, user_id, ontology_version_id)
    references semantic_private.semantic_runs(id, user_id, ontology_version_id)
    on delete cascade,
  constraint youtube_run_policies_version_check check (
    char_length(policy_version) between 1 and 80
  ),
  constraint youtube_run_policies_approval_shape_check check (
    (
      not allow_channel_identity and not allow_role_resolution
      and not allow_uploader_tags and not allow_title_tags
      and not allow_cross_source_fusion and not allow_bio
      and not allow_icebreaker and not allow_explanation
    ) or approval_id is not null
  ),
  constraint youtube_run_policies_resolver_shape_check check (
    not (
      allow_channel_identity or allow_role_resolution
      or allow_uploader_tags or allow_title_tags
    ) or youtube_resolver_model_id is not null
  ),
  constraint youtube_run_policies_surface_scope_check check (
    (not allow_bio or allow_cross_source_fusion)
    and (not allow_icebreaker or allow_cross_source_fusion)
    and (not allow_explanation or (allow_bio or allow_icebreaker))
  )
);

create or replace function semantic_private.guard_youtube_run_policy()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  approval ontology.youtube_policy_approvals%rowtype;
  resolver_role text;
  resolver_status text;
begin
  if new.youtube_resolver_model_id is not null then
    select model_role, status into resolver_role, resolver_status
    from ontology.model_versions where id = new.youtube_resolver_model_id;
    if resolver_role is distinct from 'youtube_resolver'
       or resolver_status is distinct from 'active' then
      raise exception 'YouTube policy requires an active youtube_resolver model';
    end if;
  end if;
  if new.approval_id is null then return new; end if;
  select * into approval
  from ontology.youtube_policy_approvals where id = new.approval_id;
  if not found or approval.approval_state <> 'approved'
     or approval.approved_at > now()
     or (approval.expires_at is not null and approval.expires_at <= now()) then
    raise exception 'YouTube policy approval is not currently active';
  end if;
  if (new.allow_channel_identity and not approval.allow_channel_identity)
     or (new.allow_role_resolution and not approval.allow_role_resolution)
     or (new.allow_uploader_tags and not approval.allow_uploader_tags)
     or (new.allow_title_tags and not approval.allow_title_tags)
     or (new.allow_cross_source_fusion and not approval.allow_cross_source_fusion)
     or (new.allow_bio and not approval.allow_bio)
     or (new.allow_icebreaker and not approval.allow_icebreaker)
     or (new.allow_explanation and not approval.allow_explanation) then
    raise exception 'YouTube run policy exceeds its approval scope';
  end if;
  return new;
end;
$$;

drop trigger if exists youtube_run_policies_guard_approval
  on semantic_private.youtube_run_policies;
create trigger youtube_run_policies_guard_approval
before insert or update on semantic_private.youtube_run_policies
for each row execute function semantic_private.guard_youtube_run_policy();

create or replace function semantic_private.initialize_youtube_run_policy()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  insert into semantic_private.youtube_run_policies (
    semantic_run_id, user_id, ontology_version_id
  ) values (new.id, new.user_id, new.ontology_version_id)
  on conflict (semantic_run_id) do nothing;
  return new;
end;
$$;

drop trigger if exists semantic_runs_initialize_youtube_policy
  on semantic_private.semantic_runs;
create trigger semantic_runs_initialize_youtube_policy
after insert on semantic_private.semantic_runs
for each row execute function semantic_private.initialize_youtube_run_policy();

insert into semantic_private.youtube_run_policies (
  semantic_run_id, user_id, ontology_version_id
)
select id, user_id, ontology_version_id from semantic_private.semantic_runs
on conflict (semantic_run_id) do nothing;

create or replace function semantic_private.youtube_run_gate_allowed(
  target_semantic_run_id uuid,
  gate_name text
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select approval.approval_state = 'approved'
       and approval.approved_at <= now()
       and (approval.expires_at is null or approval.expires_at > now())
       and case gate_name
         when 'channel_identity' then policy.allow_channel_identity
           and approval.allow_channel_identity
         when 'role_resolution' then policy.allow_role_resolution
           and approval.allow_role_resolution
         when 'uploader_tags' then policy.allow_uploader_tags
           and approval.allow_uploader_tags
         when 'title_tags' then policy.allow_title_tags
           and approval.allow_title_tags
         when 'cross_source_fusion' then policy.allow_cross_source_fusion
           and approval.allow_cross_source_fusion
         when 'bio' then policy.allow_bio and approval.allow_bio
         when 'icebreaker' then policy.allow_icebreaker
           and approval.allow_icebreaker
         when 'explanation' then policy.allow_explanation
           and approval.allow_explanation
         else false
       end
    from semantic_private.youtube_run_policies as policy
    join ontology.youtube_policy_approvals as approval
      on approval.id = policy.approval_id
    where policy.semantic_run_id = target_semantic_run_id
  ), false);
$$;

create or replace function semantic_private.guard_youtube_mapping_fusion()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  mapped_source text;
  required_gate text;
begin
  select source_code into mapped_source
  from semantic_private.observations
  where id = new.observation_id and user_id = new.user_id;
  if mapped_source <> 'youtube' and new.youtube_semantic_kind is not null then
    raise exception 'YouTube semantic kind cannot label another source';
  end if;
  if mapped_source = 'youtube' then
    if new.youtube_semantic_kind is null then
      raise exception 'YouTube mapping requires a typed semantic kind';
    end if;
    required_gate := case new.youtube_semantic_kind
      when 'channel_identity' then 'channel_identity'
      when 'channel_role' then 'role_resolution'
      when 'uploader_tag' then 'uploader_tags'
      when 'written_title_tag' then 'title_tags'
      else null
    end;
    if required_gate is not null and not semantic_private.youtube_run_gate_allowed(
      new.semantic_run_id, required_gate
    ) then
      raise exception 'YouTube mapping semantic kind is not approved for this run';
    end if;
    if new.cross_source_fusion_allowed
       and not semantic_private.youtube_run_gate_allowed(
         new.semantic_run_id, 'cross_source_fusion'
       ) then
      raise exception 'YouTube mapping cross-source fusion is not approved for this run';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists observation_mappings_guard_youtube_fusion
  on semantic_private.observation_mappings;
create trigger observation_mappings_guard_youtube_fusion
before insert or update of
  semantic_run_id, observation_id, user_id, cross_source_fusion_allowed,
  youtube_semantic_kind
on semantic_private.observation_mappings
for each row execute function semantic_private.guard_youtube_mapping_fusion();

-- -------------------------------------------------------------------------
-- Stable YouTube resources and reviewed role/entity resolution.
-- -------------------------------------------------------------------------

create table if not exists ontology.youtube_channels (
  id uuid primary key default extensions.gen_random_uuid(),
  youtube_channel_id text not null,
  canonical_title text,
  provider_payload_hash text,
  first_seen_at timestamptz not null default now(),
  last_refreshed_at timestamptz,
  lifecycle_state text not null default 'active',
  created_at timestamptz not null default now(),
  constraint youtube_channels_provider_id_unique unique (youtube_channel_id),
  constraint youtube_channels_provider_id_format_check check (
    char_length(youtube_channel_id) between 3 and 128
    and youtube_channel_id ~ '^[A-Za-z0-9_-]+$'
  ),
  constraint youtube_channels_lifecycle_check check (
    lifecycle_state in ('active', 'retired', 'unavailable')
  ),
  constraint youtube_channels_title_length_check check (
    canonical_title is null or char_length(canonical_title) between 1 and 240
  )
);

create table if not exists ontology.youtube_channel_resolutions (
  id uuid primary key default extensions.gen_random_uuid(),
  youtube_channel_row_id uuid not null
    references ontology.youtube_channels(id) on delete restrict,
  ontology_version_id uuid not null
    references ontology.versions(id) on delete restrict,
  channel_role text not null,
  represented_concept_id uuid,
  identity_match_method text not null,
  exact_identity_match boolean not null default false,
  review_state text not null default 'pending',
  resolution_version text not null,
  evidence jsonb not null default '{}'::jsonb,
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint youtube_channel_resolutions_role_check check (channel_role in (
    'official_creator', 'publisher', 'topical', 'fan_repost', 'unknown'
  )),
  constraint youtube_channel_resolutions_method_check check (
    identity_match_method in (
      'provider_channel_id', 'wikidata_p2397', 'curated_exact',
      'metadata_candidate', 'unknown'
    )
  ),
  constraint youtube_channel_resolutions_review_state_check check (
    review_state in ('pending', 'approved', 'rejected')
  ),
  constraint youtube_channel_resolutions_review_time_check check (
    (review_state = 'pending' and reviewed_at is null) or
    (review_state in ('approved', 'rejected') and reviewed_at is not null)
  ),
  constraint youtube_channel_resolutions_exact_concept_check check (
    represented_concept_id is null or (
      exact_identity_match
      and review_state = 'approved'
      and reviewed_at is not null
      and channel_role in ('official_creator', 'publisher', 'topical')
      and identity_match_method in (
        'provider_channel_id', 'wikidata_p2397', 'curated_exact'
      )
    )
  ),
  constraint youtube_channel_resolutions_version_unique unique (
    youtube_channel_row_id, ontology_version_id, resolution_version
  ),
  constraint youtube_channel_resolutions_composite_unique unique (
    id, youtube_channel_row_id, ontology_version_id
  ),
  foreign key (ontology_version_id, represented_concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict
);

drop trigger if exists youtube_channel_resolutions_set_updated_at
  on ontology.youtube_channel_resolutions;
create trigger youtube_channel_resolutions_set_updated_at
before update on ontology.youtube_channel_resolutions
for each row execute function semantic_private.set_updated_at();

create or replace function ontology.guard_youtube_channel_resolution_role()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  represented_kind text;
begin
  if new.represented_concept_id is null then return new; end if;
  select concept_kind into represented_kind
  from ontology.concept_revisions
  where ontology_version_id = new.ontology_version_id
    and concept_id = new.represented_concept_id;
  if (new.channel_role = 'official_creator' and represented_kind <> 'creator')
     or (new.channel_role = 'publisher' and represented_kind <> 'organization')
     or (new.channel_role = 'topical'
       and represented_kind not in ('topic', 'organization', 'hub'))
     or new.channel_role in ('fan_repost', 'unknown') then
    raise exception 'represented concept kind % is incompatible with channel role %',
      coalesce(represented_kind, '<missing>'), new.channel_role;
  end if;
  return new;
end;
$$;

drop trigger if exists youtube_channel_resolutions_guard_role
  on ontology.youtube_channel_resolutions;
create trigger youtube_channel_resolutions_guard_role
before insert or update of
  represented_concept_id, channel_role, ontology_version_id
on ontology.youtube_channel_resolutions
for each row execute function ontology.guard_youtube_channel_resolution_role();

create table if not exists semantic_private.youtube_observation_channels (
  semantic_run_id uuid not null,
  observation_id uuid not null,
  user_id uuid not null,
  youtube_channel_row_id uuid not null,
  channel_resolution_id uuid not null,
  ontology_version_id uuid not null,
  observation_relation text not null,
  target_semantics text not null,
  evidence_weight double precision not null,
  mapping_agreement double precision not null,
  evidence_quality double precision not null,
  recency_weight double precision not null default 1.0,
  recency_quality double precision not null default 1.0,
  recency_policy_version text not null default 'legacy-unversioned',
  recency_rule_id text not null default 'legacy.static',
  recency_status text not null default 'not_recorded',
  recency_timestamp_quality text not null default 'not_recorded',
  recency_as_of timestamptz not null,
  cross_source_fusion_allowed boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (
    semantic_run_id, observation_id, channel_resolution_id,
    observation_relation
  ),
  foreign key (semantic_run_id, user_id, ontology_version_id)
    references semantic_private.youtube_run_policies(
      semantic_run_id, user_id, ontology_version_id
    ) on delete cascade,
  foreign key (observation_id, user_id)
    references semantic_private.observations(id, user_id) on delete cascade,
  foreign key (
    channel_resolution_id, youtube_channel_row_id, ontology_version_id
  ) references ontology.youtube_channel_resolutions(
    id, youtube_channel_row_id, ontology_version_id
  ) on delete restrict,
  constraint youtube_observation_channels_relation_check check (
    observation_relation in ('uploaded_by', 'subscribed_to')
  ),
  constraint youtube_observation_channels_target_check check (
    target_semantics in (
      'channel_identity', 'represented_creator', 'publisher_identity',
      'topical_channel'
    )
  ),
  constraint youtube_observation_channels_relation_target_check check (
    observation_relation <> 'uploaded_by'
    or target_semantics in ('channel_identity', 'represented_creator', 'publisher_identity')
  ),
  constraint youtube_observation_channels_weight_check check (
    evidence_weight between 0 and 1
  ),
  constraint youtube_observation_channels_agreement_check check (
    mapping_agreement between 0 and 1
  ),
  constraint youtube_observation_channels_quality_check check (
    evidence_quality between 0 and 1
  ),
  constraint youtube_observation_channels_recency_check check (
    semantic_private.recency_audit_is_valid(
      recency_weight, recency_quality, recency_policy_version,
      recency_rule_id, recency_status, recency_timestamp_quality
    )
  )
);

drop trigger if exists youtube_observation_channels_pin_run_recency
  on semantic_private.youtube_observation_channels;
create trigger youtube_observation_channels_pin_run_recency
before insert or update of semantic_run_id, user_id, recency_as_of
on semantic_private.youtube_observation_channels
for each row execute function semantic_private.pin_recency_to_semantic_run();

create or replace function semantic_private.guard_youtube_channel_relation()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  resolved_role text;
  resolved_concept uuid;
  resolved_exact boolean;
  resolved_review text;
  observation_type text;
begin
  if new.target_semantics = 'channel_identity'
     and not semantic_private.youtube_run_gate_allowed(
       new.semantic_run_id, 'channel_identity'
     ) then
    raise exception 'YouTube channel identity is not approved for this run';
  end if;
  if new.target_semantics <> 'channel_identity'
     and not semantic_private.youtube_run_gate_allowed(
       new.semantic_run_id, 'role_resolution'
     ) then
    raise exception 'YouTube role resolution is not approved for this run';
  end if;
  if new.cross_source_fusion_allowed
     and not semantic_private.youtube_run_gate_allowed(
       new.semantic_run_id, 'cross_source_fusion'
     ) then
    raise exception 'YouTube channel evidence cannot enter cross-source fusion';
  end if;
  select channel_role, represented_concept_id, exact_identity_match, review_state
  into resolved_role, resolved_concept, resolved_exact, resolved_review
  from ontology.youtube_channel_resolutions
  where id = new.channel_resolution_id
    and youtube_channel_row_id = new.youtube_channel_row_id
    and ontology_version_id = new.ontology_version_id;
  select data_type into observation_type
  from semantic_private.observations
  where id = new.observation_id and user_id = new.user_id;
  if new.target_semantics = 'represented_creator' and (
    resolved_role <> 'official_creator'
    or resolved_concept is null
    or not resolved_exact
    or resolved_review <> 'approved'
  ) then
    raise exception 'represented creator requires an exact approved official channel';
  end if;
  if new.target_semantics = 'publisher_identity'
     and resolved_role <> 'publisher' then
    raise exception 'publisher semantics require a publisher channel role';
  end if;
  if new.target_semantics = 'topical_channel'
     and resolved_role <> 'topical' then
    raise exception 'topical semantics require a topical channel role';
  end if;
  if resolved_role in ('fan_repost', 'unknown')
     and new.target_semantics <> 'channel_identity' then
    raise exception 'fan/repost and unknown channels cannot project entity semantics';
  end if;
  if observation_type in ('liked', 'liked_video', 'video', 'watched', 'shared')
     and new.target_semantics = 'represented_creator'
     and new.evidence_weight > 0.35 then
    raise exception 'one video can provide only weak represented-creator evidence';
  end if;
  return new;
end;
$$;

drop trigger if exists youtube_observation_channels_guard_relation
  on semantic_private.youtube_observation_channels;
create trigger youtube_observation_channels_guard_relation
before insert or update on semantic_private.youtube_observation_channels
for each row execute function semantic_private.guard_youtube_channel_relation();

-- -------------------------------------------------------------------------
-- Calendar classification and private travel evidence.
-- Calendar rows are allowlisted, never made public by default. Raw itinerary
-- evidence remains private even when a later user-confirmed fact is nameable.
-- -------------------------------------------------------------------------

create table if not exists semantic_private.calendar_event_classifications (
  id uuid primary key default extensions.gen_random_uuid(),
  observation_id uuid not null,
  user_id uuid not null,
  classifier_model_id uuid not null
    references ontology.model_versions(id) on delete restrict,
  event_class text not null,
  disposition text not null,
  mapping_agreement double precision not null,
  evidence_quality double precision not null,
  visibility_scope text not null default 'private_evidence',
  feature_snapshot jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (id, user_id, observation_id),
  unique (observation_id, classifier_model_id),
  foreign key (observation_id, user_id)
    references semantic_private.observations(id, user_id) on delete cascade,
  constraint calendar_classifications_event_class_check check (event_class in (
    'travel_itinerary', 'commercial_reservation', 'public_ticketed_event',
    'birthday', 'medical', 'friend_private', 'work_meeting',
    'funeral_memorial', 'other_private', 'unknown'
  )),
  constraint calendar_classifications_disposition_check check (
    disposition in ('eligible_private_semantics', 'excluded_private', 'review')
  ),
  constraint calendar_classifications_private_scope_check check (
    visibility_scope = 'private_evidence'
  ),
  constraint calendar_classifications_agreement_check check (
    mapping_agreement between 0 and 1
  ),
  constraint calendar_classifications_quality_check check (
    evidence_quality between 0 and 1
  ),
  constraint calendar_classifications_sensitive_excluded_check check (
    event_class not in (
      'birthday', 'medical', 'friend_private', 'work_meeting',
      'funeral_memorial', 'other_private'
    ) or disposition = 'excluded_private'
  ),
  constraint calendar_classifications_allowlist_check check (
    disposition <> 'eligible_private_semantics'
    or event_class in (
      'travel_itinerary', 'commercial_reservation', 'public_ticketed_event'
    )
  )
);

create or replace function semantic_private.guard_calendar_observation_mapping()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  mapped_source text;
begin
  select observation.source_code into mapped_source
  from semantic_private.observations as observation
  where observation.id = new.observation_id
    and observation.user_id = new.user_id;
  if mapped_source not in ('apple_calendar', 'google_calendar') then
    return new;
  end if;
  if not exists (
    select 1
    from semantic_private.calendar_event_classifications as classification
    where classification.observation_id = new.observation_id
      and classification.user_id = new.user_id
      and classification.disposition = 'eligible_private_semantics'
      and classification.event_class in (
        'travel_itinerary', 'commercial_reservation',
        'public_ticketed_event'
      )
  ) then
    raise exception
      'calendar mappings require an eligible allowlisted classification';
  end if;
  return new;
end;
$$;

drop trigger if exists observation_mappings_guard_calendar_classification
  on semantic_private.observation_mappings;
create trigger observation_mappings_guard_calendar_classification
before insert or update of observation_id, user_id
on semantic_private.observation_mappings
for each row execute function semantic_private.guard_calendar_observation_mapping();

create table if not exists semantic_private.travel_segments (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  calendar_classification_id uuid not null,
  source_observation_id uuid not null,
  ontology_version_id uuid not null,
  segment_lineage_hmac text not null,
  origin_place_concept_id uuid,
  destination_place_concept_id uuid not null,
  origin_code text,
  destination_code text,
  departure_at timestamptz,
  arrival_at timestamptz,
  segment_state text not null,
  evidence_semantics text not null default 'scheduled_travel',
  visibility_scope text not null default 'private_evidence',
  extraction_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (id, user_id),
  unique (id, user_id, ontology_version_id),
  unique (user_id, ontology_version_id, segment_lineage_hmac),
  unique (
    id, user_id, ontology_version_id, destination_place_concept_id
  ),
  foreign key (
    calendar_classification_id, user_id, source_observation_id
  ) references semantic_private.calendar_event_classifications(
    id, user_id, observation_id
  ) on delete cascade,
  foreign key (ontology_version_id, origin_place_concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict,
  foreign key (ontology_version_id, destination_place_concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict,
  constraint travel_segments_distinct_places_check check (
    origin_place_concept_id is null
    or origin_place_concept_id <> destination_place_concept_id
  ),
  constraint travel_segments_lineage_hmac_check check (
    segment_lineage_hmac ~ '^[0-9a-f]{64}$'
  ),
  constraint travel_segments_time_order_check check (
    arrival_at is null or departure_at is null or arrival_at > departure_at
  ),
  constraint travel_segments_state_check check (segment_state in (
    'planned', 'cancelled', 'past_scheduled', 'user_confirmed_completed'
  )),
  constraint travel_segments_scheduled_semantics_check check (
    evidence_semantics = 'scheduled_travel'
  ),
  constraint travel_segments_private_scope_check check (
    visibility_scope = 'private_evidence'
  ),
  constraint travel_segments_origin_code_check check (
    origin_code is null or origin_code ~ '^[A-Z0-9]{3,8}$'
  ),
  constraint travel_segments_destination_code_check check (
    destination_code is null or destination_code ~ '^[A-Z0-9]{3,8}$'
  )
);

create or replace function semantic_private.guard_travel_segment_classification()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from semantic_private.calendar_event_classifications as classification
    where classification.id = new.calendar_classification_id
      and classification.user_id = new.user_id
      and classification.observation_id = new.source_observation_id
      and classification.event_class = 'travel_itinerary'
      and classification.disposition = 'eligible_private_semantics'
  ) then
    raise exception 'travel segment requires an allowlisted itinerary classification';
  end if;
  return new;
end;
$$;

drop trigger if exists travel_segments_guard_classification
  on semantic_private.travel_segments;
create trigger travel_segments_guard_classification
before insert or update on semantic_private.travel_segments
for each row execute function semantic_private.guard_travel_segment_classification();

create table if not exists semantic_private.travel_segment_sources (
  travel_segment_id uuid not null,
  user_id uuid not null,
  ontology_version_id uuid not null,
  calendar_classification_id uuid not null,
  source_observation_id uuid not null,
  source_role text not null,
  created_at timestamptz not null default now(),
  primary key (travel_segment_id, source_observation_id),
  unique (calendar_classification_id),
  foreign key (travel_segment_id, user_id, ontology_version_id)
    references semantic_private.travel_segments(id, user_id, ontology_version_id)
    on delete cascade,
  foreign key (
    calendar_classification_id, user_id, source_observation_id
  ) references semantic_private.calendar_event_classifications(
    id, user_id, observation_id
  ) on delete cascade,
  constraint travel_segment_sources_role_check check (
    source_role in ('primary', 'mirror')
  )
);

create unique index if not exists travel_segment_one_primary_source_idx
  on semantic_private.travel_segment_sources (travel_segment_id)
  where source_role = 'primary';

create or replace function semantic_private.guard_travel_segment_source()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  source_lineage text;
  segment_lineage text;
begin
  if not exists (
    select 1
    from semantic_private.calendar_event_classifications as classification
    where classification.id = new.calendar_classification_id
      and classification.user_id = new.user_id
      and classification.observation_id = new.source_observation_id
      and classification.event_class = 'travel_itinerary'
      and classification.disposition = 'eligible_private_semantics'
  ) then
    raise exception 'segment source requires an allowlisted itinerary classification';
  end if;
  select observation.content_lineage_hmac, segment.segment_lineage_hmac
  into source_lineage, segment_lineage
  from semantic_private.observations as observation
  join semantic_private.travel_segments as segment
    on segment.id = new.travel_segment_id
   and segment.user_id = new.user_id
   and segment.ontology_version_id = new.ontology_version_id
  where observation.id = new.source_observation_id
    and observation.user_id = new.user_id;
  if source_lineage is distinct from segment_lineage then
    raise exception 'segment source lineage must match its canonical HMAC';
  end if;
  return new;
end;
$$;

drop trigger if exists travel_segment_sources_guard_classification
  on semantic_private.travel_segment_sources;
create trigger travel_segment_sources_guard_classification
before insert or update on semantic_private.travel_segment_sources
for each row execute function semantic_private.guard_travel_segment_source();

create or replace function semantic_private.initialize_travel_segment_primary_source()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  insert into semantic_private.travel_segment_sources (
    travel_segment_id, user_id, ontology_version_id,
    calendar_classification_id,
    source_observation_id, source_role
  ) values (
    new.id, new.user_id, new.ontology_version_id,
    new.calendar_classification_id,
    new.source_observation_id, 'primary'
  )
  on conflict (travel_segment_id, source_observation_id) do nothing;
  return new;
end;
$$;

drop trigger if exists travel_segments_initialize_primary_source
  on semantic_private.travel_segments;
create trigger travel_segments_initialize_primary_source
after insert on semantic_private.travel_segments
for each row execute function semantic_private.initialize_travel_segment_primary_source();

insert into semantic_private.travel_segment_sources (
  travel_segment_id, user_id, ontology_version_id,
  calendar_classification_id,
  source_observation_id, source_role
)
select segment.id, segment.user_id, segment.ontology_version_id,
       segment.calendar_classification_id,
       segment.source_observation_id, 'primary'
from semantic_private.travel_segments as segment
on conflict (travel_segment_id, source_observation_id) do nothing;

create table if not exists semantic_private.travel_journeys (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  ontology_version_id uuid not null
    references ontology.versions(id) on delete restrict,
  journey_lineage_hmac text not null,
  round_trip_group_hmac text,
  journey_state text not null,
  window_start timestamptz,
  window_end timestamptz,
  anchor_place_concept_id uuid,
  terminal_place_concept_id uuid not null,
  visibility_scope text not null default 'private_evidence',
  derivation_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (id, user_id),
  unique (id, user_id, ontology_version_id),
  unique (
    id, user_id, ontology_version_id, terminal_place_concept_id
  ),
  unique (user_id, ontology_version_id, journey_lineage_hmac),
  foreign key (ontology_version_id, anchor_place_concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict,
  foreign key (ontology_version_id, terminal_place_concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict,
  constraint travel_journeys_state_check check (journey_state in (
    'planned', 'past_scheduled', 'user_confirmed_completed', 'cancelled'
  )),
  constraint travel_journeys_window_check check (
    window_end is null or window_start is null or window_end > window_start
  ),
  constraint travel_journeys_lineage_hmac_check check (
    journey_lineage_hmac ~ '^[0-9a-f]{64}$'
  ),
  constraint travel_journeys_round_trip_hmac_check check (
    round_trip_group_hmac is null
    or round_trip_group_hmac ~ '^[0-9a-f]{64}$'
  ),
  constraint travel_journeys_private_scope_check check (
    visibility_scope = 'private_evidence'
  )
);

create table if not exists semantic_private.travel_journey_segments (
  journey_id uuid not null,
  segment_id uuid not null,
  user_id uuid not null,
  ontology_version_id uuid not null,
  segment_order integer not null,
  segment_role text not null,
  created_at timestamptz not null default now(),
  primary key (journey_id, segment_id),
  foreign key (journey_id, user_id, ontology_version_id)
    references semantic_private.travel_journeys(id, user_id, ontology_version_id)
    on delete cascade,
  foreign key (segment_id, user_id, ontology_version_id)
    references semantic_private.travel_segments(id, user_id, ontology_version_id)
    on delete cascade,
  constraint travel_journey_segments_order_check check (segment_order >= 0),
  constraint travel_journey_segments_role_check check (
    segment_role in ('outbound', 'connection', 'terminal', 'return', 'one_way')
  ),
  constraint travel_journey_segments_order_unique unique (
    journey_id, segment_order
  )
);

create unique index if not exists travel_journey_one_terminal_segment_idx
  on semantic_private.travel_journey_segments (journey_id)
  where segment_role in ('terminal', 'one_way');

create or replace function semantic_private.guard_travel_journey_segment_role()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  journey_terminal uuid;
  segment_destination uuid;
begin
  select terminal_place_concept_id into journey_terminal
  from semantic_private.travel_journeys
  where id = new.journey_id
    and user_id = new.user_id
    and ontology_version_id = new.ontology_version_id;
  select destination_place_concept_id into segment_destination
  from semantic_private.travel_segments
  where id = new.segment_id
    and user_id = new.user_id
    and ontology_version_id = new.ontology_version_id;
  if new.segment_role in ('terminal', 'one_way')
     and segment_destination is distinct from journey_terminal then
    raise exception 'terminal journey segment must end at the journey terminal';
  end if;
  if new.segment_role = 'connection'
     and segment_destination is not distinct from journey_terminal then
    raise exception 'connection segment cannot be the journey terminal';
  end if;
  return new;
end;
$$;

drop trigger if exists travel_journey_segments_guard_role
  on semantic_private.travel_journey_segments;
create trigger travel_journey_segments_guard_role
before insert or update on semantic_private.travel_journey_segments
for each row execute function semantic_private.guard_travel_journey_segment_role();

create table if not exists semantic_private.recurring_place_candidates (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  ontology_version_id uuid not null,
  place_concept_id uuid not null,
  candidate_kind text not null,
  proposed_predicate_key text not null,
  distinct_journey_count integer not null,
  distinct_month_count integer not null,
  complete_round_trip_count integer not null default 0,
  window_start timestamptz not null,
  window_end timestamptz not null,
  strength double precision not null,
  mapping_agreement double precision not null,
  evidence_quality double precision not null,
  confirmation_state text not null default 'machine_candidate',
  wording_state text not null default 'private_review',
  public_naming_allowed boolean not null default false,
  public_explanation_allowed boolean not null default false,
  derivation_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  foreign key (ontology_version_id, place_concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict,
  constraint recurring_place_candidates_kind_check check (candidate_kind in (
    'recurring_destination', 'recurring_origin', 'home_base_candidate'
  )),
  constraint recurring_place_candidates_predicate_check check (
    proposed_predicate_key in ('recurring_presence_at', 'home_base_candidate')
    and proposed_predicate_key not in ('hometown', 'lives_in')
  ),
  constraint recurring_place_candidates_counts_check check (
    distinct_journey_count >= 2
    and distinct_month_count >= 2
    and complete_round_trip_count >= 0
  ),
  constraint recurring_place_candidates_window_check check (
    window_end >= window_start + interval '90 days'
  ),
  constraint recurring_place_candidates_strength_check check (
    strength between 0 and 1
  ),
  constraint recurring_place_candidates_agreement_check check (
    mapping_agreement between 0 and 1
  ),
  constraint recurring_place_candidates_quality_check check (
    evidence_quality between 0 and 1
  ),
  constraint recurring_place_candidates_confirmation_check check (
    confirmation_state in ('machine_candidate', 'user_confirmed', 'user_rejected')
  ),
  constraint recurring_place_candidates_wording_state_check check (
    wording_state in (
      'private_review', 'recurring_confirmed', 'often_returns_confirmed'
    )
  ),
  constraint recurring_place_candidates_often_returns_check check (
    wording_state <> 'often_returns_confirmed' or (
      confirmation_state = 'user_confirmed'
      and candidate_kind = 'recurring_destination'
      and proposed_predicate_key = 'recurring_presence_at'
      and distinct_journey_count >= 3
      and complete_round_trip_count >= 2
      and window_end >= window_start + interval '180 days'
    )
  ),
  constraint recurring_place_candidates_public_name_check check (
    not public_naming_allowed or (
      confirmation_state = 'user_confirmed'
      and wording_state = 'often_returns_confirmed'
      and candidate_kind = 'recurring_destination'
      and proposed_predicate_key = 'recurring_presence_at'
      and distinct_journey_count >= 3
      and complete_round_trip_count >= 2
      and window_end >= window_start + interval '180 days'
    )
  ),
  constraint recurring_place_candidates_no_public_evidence_check check (
    public_explanation_allowed = false
  )
);

-- Non-flight commercial receipts use a normalized candidate record. A
-- booking is not attendance or liking, and remains Memories-only until a
-- separate explicit/confirmed user assertion exists.
create table if not exists semantic_private.booked_activity_candidates (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  calendar_classification_id uuid not null,
  source_observation_id uuid not null,
  ontology_version_id uuid not null,
  predicate_key text not null
    references ontology.relation_types(predicate_key) on delete restrict,
  target_concept_id uuid not null,
  place_concept_id uuid,
  booking_lineage_hmac text not null,
  action_semantics text not null,
  booking_state text not null,
  confirmation_state text not null default 'unconfirmed',
  strength double precision not null,
  mapping_agreement double precision not null,
  evidence_quality double precision not null,
  recency_weight double precision not null default 1.0,
  recency_quality double precision not null default 1.0,
  recency_policy_version text not null default 'legacy-unversioned',
  recency_rule_id text not null default 'legacy.static',
  recency_status text not null default 'not_recorded',
  recency_timestamp_quality text not null default 'not_recorded',
  recency_as_of timestamptz not null default now(),
  memories_naming_allowed boolean not null default true,
  matching_allowed boolean not null default false,
  public_surface_allowed boolean not null default false,
  display_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (id, user_id),
  unique (
    user_id, ontology_version_id, predicate_key, booking_lineage_hmac
  ),
  foreign key (
    calendar_classification_id, user_id, source_observation_id
  ) references semantic_private.calendar_event_classifications(
    id, user_id, observation_id
  ) on delete cascade,
  foreign key (ontology_version_id, target_concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict,
  foreign key (ontology_version_id, place_concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict,
  constraint booked_activity_candidates_predicate_check check (
    predicate_key in (
      'booked_activity_at', 'booked_event', 'scheduled_dining'
    )
  ),
  constraint booked_activity_candidates_lineage_hmac_check check (
    booking_lineage_hmac ~ '^[0-9a-f]{64}$'
  ),
  constraint booked_activity_candidates_action_check check (
    action_semantics in ('booked', 'scheduled')
  ),
  constraint booked_activity_candidates_state_check check (
    booking_state in ('planned', 'past_scheduled', 'cancelled')
  ),
  constraint booked_activity_candidates_confirmation_check check (
    confirmation_state in (
      'unconfirmed', 'user_confirmed_attended', 'user_rejected'
    )
  ),
  constraint booked_activity_candidates_strength_check check (
    strength between 0 and 1
  ),
  constraint booked_activity_candidates_agreement_check check (
    mapping_agreement between 0 and 1
  ),
  constraint booked_activity_candidates_quality_check check (
    evidence_quality between 0 and 1
  ),
  constraint booked_activity_candidates_recency_check check (
    semantic_private.recency_audit_is_valid(
      recency_weight, recency_quality, recency_policy_version,
      recency_rule_id, recency_status, recency_timestamp_quality
    )
  ),
  constraint booked_activity_candidates_private_check check (
    matching_allowed = false and public_surface_allowed = false
  )
);

create or replace function semantic_private.guard_booked_activity_candidate()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  classified_event text;
  classified_disposition text;
  source_lineage text;
begin
  select classification.event_class, classification.disposition,
         observation.content_lineage_hmac
  into classified_event, classified_disposition, source_lineage
  from semantic_private.calendar_event_classifications as classification
  join semantic_private.observations as observation
    on observation.id = classification.observation_id
   and observation.user_id = classification.user_id
  where classification.id = new.calendar_classification_id
    and classification.user_id = new.user_id
    and classification.observation_id = new.source_observation_id;
  if classified_disposition is distinct from 'eligible_private_semantics'
     or classified_event not in (
       'commercial_reservation', 'public_ticketed_event'
     ) then
    raise exception 'booked candidate requires an allowlisted commercial classification';
  end if;
  if (new.predicate_key = 'booked_event'
        and classified_event <> 'public_ticketed_event')
     or (new.predicate_key = 'scheduled_dining'
        and classified_event <> 'commercial_reservation') then
    raise exception 'booked candidate predicate is incompatible with event class';
  end if;
  if source_lineage is distinct from new.booking_lineage_hmac then
    raise exception 'booked candidate lineage must match its source observation';
  end if;
  return new;
end;
$$;

drop trigger if exists booked_activity_candidates_guard_classification
  on semantic_private.booked_activity_candidates;
create trigger booked_activity_candidates_guard_classification
before insert or update on semantic_private.booked_activity_candidates
for each row execute function semantic_private.guard_booked_activity_candidate();

-- A single structured ticket is useful immediately as a private scheduled-
-- travel Memory. It does not need recurrence and does not license completed
-- travel, affinity, residence, or hometown wording.
create table if not exists semantic_private.scheduled_travel_candidates (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  travel_journey_id uuid not null,
  ontology_version_id uuid not null,
  destination_place_concept_id uuid not null,
  action_semantics text not null,
  strength double precision not null,
  mapping_agreement double precision not null,
  evidence_quality double precision not null,
  recency_weight double precision not null default 1.0,
  recency_quality double precision not null default 1.0,
  recency_policy_version text not null default 'legacy-unversioned',
  recency_rule_id text not null default 'legacy.static',
  recency_status text not null default 'not_recorded',
  recency_timestamp_quality text not null default 'not_recorded',
  recency_as_of timestamptz not null default now(),
  candidate_state text not null default 'eligible',
  memories_naming_allowed boolean not null default true,
  public_surface_allowed boolean not null default false,
  display_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (id, user_id),
  unique (travel_journey_id),
  foreign key (
    travel_journey_id, user_id, ontology_version_id,
    destination_place_concept_id
  ) references semantic_private.travel_journeys(
    id, user_id, ontology_version_id, terminal_place_concept_id
  ) on delete cascade,
  constraint scheduled_travel_candidates_action_check check (
    action_semantics in ('scheduled', 'booked')
  ),
  constraint scheduled_travel_candidates_strength_check check (
    strength between 0 and 1
  ),
  constraint scheduled_travel_candidates_agreement_check check (
    mapping_agreement between 0 and 1
  ),
  constraint scheduled_travel_candidates_quality_check check (
    evidence_quality between 0 and 1
  ),
  constraint scheduled_travel_candidates_recency_check check (
    semantic_private.recency_audit_is_valid(
      recency_weight, recency_quality, recency_policy_version,
      recency_rule_id, recency_status, recency_timestamp_quality
    )
  ),
  constraint scheduled_travel_candidates_state_check check (
    candidate_state in ('candidate', 'eligible', 'suppressed', 'expired')
  ),
  constraint scheduled_travel_candidates_private_check check (
    public_surface_allowed = false
  ),
  constraint scheduled_travel_candidates_no_raw_payload_check check (
    not (display_payload ?| array[
      'raw_observation', 'raw_calendar', 'ticket', 'itinerary',
      'observation_id'
    ])
  )
);

create or replace function semantic_private.guard_scheduled_travel_journey_terminal()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from semantic_private.travel_journeys as journey
    join semantic_private.travel_journey_segments as link
      on link.journey_id = journey.id
     and link.user_id = journey.user_id
     and link.ontology_version_id = journey.ontology_version_id
     and link.segment_role in ('terminal', 'one_way')
    join semantic_private.travel_segments as segment
      on segment.id = link.segment_id
     and segment.user_id = link.user_id
     and segment.ontology_version_id = link.ontology_version_id
    where journey.id = new.travel_journey_id
      and journey.user_id = new.user_id
      and journey.ontology_version_id = new.ontology_version_id
      and journey.terminal_place_concept_id = new.destination_place_concept_id
      and journey.journey_state <> 'cancelled'
      and segment.destination_place_concept_id =
        journey.terminal_place_concept_id
      and segment.segment_state <> 'cancelled'
  ) then
    raise exception 'scheduled travel candidate requires a non-transit journey terminal';
  end if;
  return new;
end;
$$;

drop trigger if exists scheduled_travel_candidates_guard_terminal
  on semantic_private.scheduled_travel_candidates;
create trigger scheduled_travel_candidates_guard_terminal
before insert or update on semantic_private.scheduled_travel_candidates
for each row execute function semantic_private.guard_scheduled_travel_journey_terminal();

-- Reinforce the existing relation-class trigger with an invariant that remains
-- true even if a future migration accidentally marks these predicates safe.
create or replace function semantic_private.guard_user_assertion_relation_class()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  actual_class text;
  safe_for_assertions boolean;
  revision_status text;
  revision_sensitivity text;
  revision_inference_policy text;
begin
  select relation_class, assertion_safe
  into actual_class, safe_for_assertions
  from ontology.relation_types
  where predicate_key = new.predicate_key;
  if actual_class is distinct from 'user_claim' then
    raise exception 'user assertion predicate % must be a user_claim',
      new.predicate_key;
  end if;
  if new.assertion_origin = 'inferred'
     and new.predicate_key in ('hometown', 'lives_in') then
    raise exception 'machine inference cannot create % assertions',
      new.predicate_key;
  end if;
  if new.assertion_origin = 'inferred'
     and safe_for_assertions is distinct from true then
    raise exception 'inferred assertion predicate % is not assertion-safe',
      new.predicate_key;
  end if;
  if new.assertion_origin = 'inferred' and new.concept_id is not null then
    select status, sensitivity, inference_policy
    into revision_status, revision_sensitivity, revision_inference_policy
    from ontology.concept_revisions
    where ontology_version_id = new.created_ontology_version_id
      and concept_id = new.concept_id;
    if revision_status is distinct from 'active'
       or revision_sensitivity = 'sensitive'
       or revision_inference_policy not in ('inferable', 'review_required')
    then
      raise exception 'concept is not eligible for inferred user assertions';
    end if;
  end if;
  return new;
end;
$$;

-- -------------------------------------------------------------------------
-- Assertion surface permissions and expanded owner feedback surfaces.
-- Selection, naming, and evidence explanation are deliberately independent.
-- -------------------------------------------------------------------------

alter table semantic_private.assertion_exposures
  drop constraint if exists assertion_exposures_surface_check,
  drop constraint if exists assertion_exposures_surface_v02_check,
  add constraint assertion_exposures_surface_v02_check check (
    surface in ('memories', 'matching', 'bio', 'icebreaker')
  );
alter table semantic_private.user_suppressions
  drop constraint if exists user_suppressions_surface_check,
  drop constraint if exists user_suppressions_surface_v02_check,
  add constraint user_suppressions_surface_v02_check check (
    surface in ('memories', 'matching', 'bio', 'icebreaker')
  );

create or replace function semantic_private.assert_surface_allowed(surface_name text)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if surface_name is null or surface_name not in (
    'memories', 'matching', 'bio', 'icebreaker'
  ) then
    raise exception 'unsupported assertion surface';
  end if;
end;
$$;

create table if not exists semantic_private.assertion_surface_permissions (
  assertion_id uuid not null,
  user_id uuid not null,
  surface text not null,
  can_select boolean not null default false,
  can_name boolean not null default false,
  can_explain boolean not null default false,
  permission_source text not null default 'default_policy',
  last_feedback_event_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (assertion_id, user_id, surface),
  foreign key (assertion_id, user_id)
    references semantic_private.user_assertions(id, user_id) on delete cascade,
  foreign key (last_feedback_event_id, user_id)
    references semantic_private.feedback_events(id, user_id)
    on delete no action deferrable initially deferred,
  constraint assertion_surface_permissions_surface_check check (
    surface in ('memories', 'matching', 'bio', 'icebreaker')
  ),
  constraint assertion_surface_permissions_lattice_check check (
    (not can_name or can_select) and (not can_explain or can_name)
  ),
  constraint assertion_surface_permissions_matching_shape_check check (
    surface <> 'matching' or (not can_name and not can_explain)
  ),
  constraint assertion_surface_permissions_source_check check (
    permission_source in ('default_policy', 'user_choice', 'policy_guard')
  )
);

drop trigger if exists assertion_surface_permissions_set_updated_at
  on semantic_private.assertion_surface_permissions;
create trigger assertion_surface_permissions_set_updated_at
before update on semantic_private.assertion_surface_permissions
for each row execute function semantic_private.set_updated_at();

create or replace function semantic_private.initialize_assertion_surface_permissions()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  insert into semantic_private.assertion_surface_permissions (
    assertion_id, user_id, surface, can_select, can_name, can_explain,
    permission_source
  ) values
    (new.id, new.user_id, 'memories', true, true, true, 'default_policy'),
    (new.id, new.user_id, 'matching', false, false, false, 'default_policy'),
    (new.id, new.user_id, 'bio', false, false, false, 'default_policy'),
    (new.id, new.user_id, 'icebreaker', false, false, false, 'default_policy')
  on conflict (assertion_id, user_id, surface) do nothing;
  return new;
end;
$$;

drop trigger if exists user_assertions_initialize_surface_permissions
  on semantic_private.user_assertions;
create trigger user_assertions_initialize_surface_permissions
after insert on semantic_private.user_assertions
for each row execute function semantic_private.initialize_assertion_surface_permissions();

insert into semantic_private.assertion_surface_permissions (
  assertion_id, user_id, surface, can_select, can_name, can_explain,
  permission_source
)
select assertion.id, assertion.user_id, surface.surface,
       surface.surface = 'memories', surface.surface = 'memories',
       surface.surface = 'memories', 'default_policy'
from semantic_private.user_assertions as assertion
cross join (
  values ('memories'), ('matching'), ('bio'), ('icebreaker')
) as surface(surface)
on conflict (assertion_id, user_id, surface) do nothing;

create or replace function semantic_private.assertion_has_calendar_evidence(
  target_assertion_id uuid,
  target_user_id uuid
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
    from semantic_private.assertion_score_versions as score
    join semantic_private.assertion_evidence as evidence
      on evidence.assertion_score_version_id = score.id
     and evidence.user_id = score.user_id
    join semantic_private.observation_mappings as mapping
      on mapping.id = evidence.observation_mapping_id
     and mapping.user_id = evidence.user_id
    join semantic_private.observations as observation
      on observation.id = mapping.observation_id
     and observation.user_id = mapping.user_id
    where score.assertion_id = target_assertion_id
      and score.user_id = target_user_id
      and observation.source_code in ('apple_calendar', 'google_calendar')
  ) or exists (
    select 1
    from semantic_private.user_assertions as assertion
    where assertion.id = target_assertion_id
      and assertion.user_id = target_user_id
      and assertion.predicate_key in (
        'recurring_presence_at', 'home_base_candidate'
      )
  );
$$;

create or replace function semantic_private.guard_calendar_surface_permission()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  assertion_origin text;
  display_state text;
begin
  if new.surface not in ('matching', 'bio', 'icebreaker')
     or not semantic_private.assertion_has_calendar_evidence(
       new.assertion_id, new.user_id
     ) then
    return new;
  end if;
  select assertion.assertion_origin,
         coalesce(preference.display_state, 'default')
  into assertion_origin, display_state
  from semantic_private.user_assertions as assertion
  left join semantic_private.assertion_preferences as preference
    on preference.assertion_id = assertion.id
   and preference.user_id = assertion.user_id
  where assertion.id = new.assertion_id and assertion.user_id = new.user_id;
  if new.can_explain then
    raise exception 'raw calendar or itinerary evidence cannot be surfaced as an explanation';
  end if;
  if new.can_select
     and assertion_origin = 'inferred'
     and display_state <> 'confirmed' then
    raise exception 'calendar-derived facts require confirmation before matching or public selection';
  end if;
  return new;
end;
$$;

drop trigger if exists assertion_permissions_guard_calendar
  on semantic_private.assertion_surface_permissions;
create trigger assertion_permissions_guard_calendar
before insert or update of can_select, can_name, can_explain, surface
on semantic_private.assertion_surface_permissions
for each row execute function semantic_private.guard_calendar_surface_permission();

create or replace function semantic_private.clear_calendar_permissions_on_downgrade()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.display_state = 'confirmed'
     and new.display_state <> 'confirmed'
     and semantic_private.assertion_has_calendar_evidence(
       new.assertion_id, new.user_id
     ) then
    update semantic_private.assertion_surface_permissions
    set can_select = false, can_name = false, can_explain = false,
        permission_source = 'policy_guard'
    where assertion_id = new.assertion_id
      and user_id = new.user_id
      and surface in ('matching', 'bio', 'icebreaker');
  end if;
  return new;
end;
$$;

drop trigger if exists assertion_preferences_clear_calendar_permissions
  on semantic_private.assertion_preferences;
create trigger assertion_preferences_clear_calendar_permissions
after update of display_state on semantic_private.assertion_preferences
for each row execute function semantic_private.clear_calendar_permissions_on_downgrade();

create or replace function semantic_private.invalidate_on_matching_permission_revocation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.surface = 'matching' and old.can_select and not new.can_select then
    update semantic_private.dyad_runs
    set status = 'stale', finished_at = coalesce(finished_at, now())
    where (viewer_user_id = new.user_id or subject_user_id = new.user_id)
      and status in ('running', 'succeeded');
  end if;
  return new;
end;
$$;

drop trigger if exists assertion_permissions_invalidate_matching_outputs
  on semantic_private.assertion_surface_permissions;
create trigger assertion_permissions_invalidate_matching_outputs
after update of can_select on semantic_private.assertion_surface_permissions
for each row execute function semantic_private.invalidate_on_matching_permission_revocation();

create or replace function semantic_private.guard_calendar_assertion_evidence()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  assertion_id_value uuid;
  source_code_value text;
  assertion_origin_value text;
  display_state_value text;
begin
  select score.assertion_id, observation.source_code
  into assertion_id_value, source_code_value
  from semantic_private.assertion_score_versions as score
  join semantic_private.observation_mappings as mapping
    on mapping.id = new.observation_mapping_id
   and mapping.user_id = new.user_id
  join semantic_private.observations as observation
    on observation.id = mapping.observation_id
   and observation.user_id = mapping.user_id
  where score.id = new.assertion_score_version_id
    and score.user_id = new.user_id;
  if source_code_value not in ('apple_calendar', 'google_calendar') then
    return new;
  end if;
  select assertion.assertion_origin,
         coalesce(preference.display_state, 'default')
  into assertion_origin_value, display_state_value
  from semantic_private.user_assertions as assertion
  left join semantic_private.assertion_preferences as preference
    on preference.assertion_id = assertion.id
   and preference.user_id = assertion.user_id
  where assertion.id = assertion_id_value and assertion.user_id = new.user_id;
  if exists (
    select 1 from semantic_private.assertion_surface_permissions as permission
    where permission.assertion_id = assertion_id_value
      and permission.user_id = new.user_id
      and permission.surface in ('matching', 'bio', 'icebreaker')
      and (
        permission.can_explain
        or (
          permission.can_select
          and assertion_origin_value = 'inferred'
          and display_state_value <> 'confirmed'
        )
      )
  ) then
    raise exception 'calendar evidence conflicts with public surface permissions';
  end if;
  return new;
end;
$$;

drop trigger if exists assertion_evidence_guard_calendar_permissions
  on semantic_private.assertion_evidence;
create trigger assertion_evidence_guard_calendar_permissions
before insert or update of assertion_score_version_id, observation_mapping_id
on semantic_private.assertion_evidence
for each row execute function semantic_private.guard_calendar_assertion_evidence();

create or replace function semantic_private.assertion_has_youtube_evidence(
  target_assertion_id uuid,
  target_user_id uuid
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
    from semantic_private.assertion_score_versions as score
    join semantic_private.assertion_evidence as evidence
      on evidence.assertion_score_version_id = score.id
     and evidence.user_id = score.user_id
    join semantic_private.observation_mappings as mapping
      on mapping.id = evidence.observation_mapping_id
     and mapping.user_id = evidence.user_id
    join semantic_private.observations as observation
      on observation.id = mapping.observation_id
     and observation.user_id = mapping.user_id
    where score.assertion_id = target_assertion_id
      and score.user_id = target_user_id
      and observation.source_code = 'youtube'
  );
$$;

create or replace function semantic_private.youtube_assertion_gate_allowed(
  target_assertion_id uuid,
  target_user_id uuid,
  requested_surface text
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select not exists (
    select 1
    from semantic_private.assertion_score_versions as score
    join semantic_private.assertion_evidence as evidence
      on evidence.assertion_score_version_id = score.id
     and evidence.user_id = score.user_id
    join semantic_private.observation_mappings as mapping
      on mapping.id = evidence.observation_mapping_id
     and mapping.user_id = evidence.user_id
    join semantic_private.observations as observation
      on observation.id = mapping.observation_id
     and observation.user_id = mapping.user_id
    where score.assertion_id = target_assertion_id
      and score.user_id = target_user_id
      and observation.source_code = 'youtube'
      and (
        not mapping.cross_source_fusion_allowed
        or not semantic_private.youtube_run_gate_allowed(
          mapping.semantic_run_id,
          case requested_surface
            when 'matching' then 'cross_source_fusion'
            when 'bio' then 'bio'
            when 'icebreaker' then 'icebreaker'
            when 'explanation' then 'explanation'
            else 'unsupported'
          end
        )
      )
  );
$$;

create or replace function semantic_private.guard_youtube_surface_permission()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.surface not in ('matching', 'bio', 'icebreaker')
     or not semantic_private.assertion_has_youtube_evidence(
       new.assertion_id, new.user_id
     ) then
    return new;
  end if;
  if new.can_select and not semantic_private.youtube_assertion_gate_allowed(
    new.assertion_id, new.user_id, new.surface
  ) then
    raise exception 'YouTube evidence is not approved for this surface';
  end if;
  if new.can_explain and not semantic_private.youtube_assertion_gate_allowed(
    new.assertion_id, new.user_id, 'explanation'
  ) then
    raise exception 'YouTube evidence explanation is not approved';
  end if;
  return new;
end;
$$;

drop trigger if exists assertion_permissions_guard_youtube
  on semantic_private.assertion_surface_permissions;
create trigger assertion_permissions_guard_youtube
before insert or update of can_select, can_name, can_explain, surface
on semantic_private.assertion_surface_permissions
for each row execute function semantic_private.guard_youtube_surface_permission();

create or replace function semantic_private.guard_youtube_assertion_evidence()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  assertion_id_value uuid;
  source_code_value text;
  mapping_run_id uuid;
  mapping_fusion_allowed boolean;
  permission record;
  gate_name text;
begin
  select score.assertion_id, observation.source_code,
         mapping.semantic_run_id, mapping.cross_source_fusion_allowed
  into assertion_id_value, source_code_value,
       mapping_run_id, mapping_fusion_allowed
  from semantic_private.assertion_score_versions as score
  join semantic_private.observation_mappings as mapping
    on mapping.id = new.observation_mapping_id
   and mapping.user_id = new.user_id
  join semantic_private.observations as observation
    on observation.id = mapping.observation_id
   and observation.user_id = mapping.user_id
  where score.id = new.assertion_score_version_id
    and score.user_id = new.user_id;
  if source_code_value <> 'youtube' then return new; end if;
  for permission in
    select surface, can_select, can_explain
    from semantic_private.assertion_surface_permissions
    where assertion_id = assertion_id_value
      and user_id = new.user_id
      and surface in ('matching', 'bio', 'icebreaker')
      and (can_select or can_explain)
  loop
    gate_name := case permission.surface
      when 'matching' then 'cross_source_fusion'
      when 'bio' then 'bio'
      when 'icebreaker' then 'icebreaker'
    end;
    if permission.can_select and (
      not mapping_fusion_allowed
      or not semantic_private.youtube_run_gate_allowed(mapping_run_id, gate_name)
    ) then
      raise exception 'YouTube assertion evidence conflicts with surface policy';
    end if;
    if permission.can_explain and not semantic_private.youtube_run_gate_allowed(
      mapping_run_id, 'explanation'
    ) then
      raise exception 'YouTube assertion evidence conflicts with explanation policy';
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists assertion_evidence_guard_youtube_permissions
  on semantic_private.assertion_evidence;
create trigger assertion_evidence_guard_youtube_permissions
before insert or update of assertion_score_version_id, observation_mapping_id
on semantic_private.assertion_evidence
for each row execute function semantic_private.guard_youtube_assertion_evidence();

create or replace function semantic_private.guard_assertion_exposure_permission()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.surface = 'matching' and not exists (
    select 1
    from semantic_private.assertion_surface_permissions as permission
    where permission.assertion_id = new.assertion_id
      and permission.user_id = new.user_id
      and permission.surface = 'matching'
      and permission.can_select
  ) then
    raise exception 'matching exposure exceeds its surface permission';
  end if;
  if new.surface in ('bio', 'icebreaker') and not exists (
    select 1
    from semantic_private.assertion_surface_permissions as permission
    where permission.assertion_id = new.assertion_id
      and permission.user_id = new.user_id
      and permission.surface = new.surface
      and permission.can_select
      and permission.can_name
  ) then
    raise exception 'named assertion exposure exceeds its surface permission';
  end if;
  return new;
end;
$$;

drop trigger if exists assertion_exposures_guard_surface_permission
  on semantic_private.assertion_exposures;
create trigger assertion_exposures_guard_surface_permission
before insert or update of assertion_id, user_id, surface
on semantic_private.assertion_exposures
for each row execute function semantic_private.guard_assertion_exposure_permission();

-- -------------------------------------------------------------------------
-- Memories presentation snapshots. Items retain assertion identity; group
-- headings never masquerade as editable assertions.
-- -------------------------------------------------------------------------

create table if not exists semantic_private.memories_snapshots (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  ontology_version_id uuid not null
    references ontology.versions(id) on delete restrict,
  builder_model_id uuid not null
    references ontology.model_versions(id) on delete restrict,
  input_revision bigint not null,
  presentation_version text not null,
  state text not null default 'building',
  metrics jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  finished_at timestamptz,
  unique (id, user_id),
  unique (user_id, input_revision, presentation_version),
  constraint memories_snapshots_revision_check check (input_revision >= 0),
  constraint memories_snapshots_state_check check (
    state in ('building', 'ready', 'stale', 'failed')
  ),
  constraint memories_snapshots_finish_check check (
    (state = 'building' and finished_at is null) or
    (state <> 'building' and finished_at is not null)
  ),
  constraint memories_snapshots_presentation_check check (
    char_length(presentation_version) between 1 and 80
  )
);

create or replace function semantic_private.guard_memories_snapshot_current()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  current_revision bigint;
begin
  if new.state <> 'ready' then return new; end if;
  select revision into current_revision
  from semantic_private.user_state_versions where user_id = new.user_id;
  if new.input_revision <> coalesce(current_revision, 0) then
    raise exception 'ready Memories snapshot requires the current user revision';
  end if;
  return new;
end;
$$;

drop trigger if exists memories_snapshots_guard_current
  on semantic_private.memories_snapshots;
create trigger memories_snapshots_guard_current
before insert or update of state, input_revision
on semantic_private.memories_snapshots
for each row execute function semantic_private.guard_memories_snapshot_current();

create table if not exists semantic_private.memories_snapshot_items (
  id uuid primary key default extensions.gen_random_uuid(),
  snapshot_id uuid not null,
  user_id uuid not null,
  parent_item_id uuid,
  assertion_id uuid,
  scheduled_travel_candidate_id uuid,
  booked_activity_candidate_id uuid,
  hub_concept_id uuid,
  item_key text not null,
  item_kind text not null,
  display_label text not null,
  rank integer not null,
  explicitness_rank integer not null default 0,
  specificity double precision not null default 0,
  affinity_strength double precision not null default 0,
  display_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (id, user_id, snapshot_id),
  unique (snapshot_id, item_key),
  unique (snapshot_id, rank),
  foreign key (snapshot_id, user_id)
    references semantic_private.memories_snapshots(id, user_id) on delete cascade,
  foreign key (parent_item_id, user_id, snapshot_id)
    references semantic_private.memories_snapshot_items(id, user_id, snapshot_id)
    on delete cascade deferrable initially deferred,
  foreign key (assertion_id, user_id)
    references semantic_private.user_assertions(id, user_id) on delete cascade,
  foreign key (scheduled_travel_candidate_id, user_id)
    references semantic_private.scheduled_travel_candidates(id, user_id)
    on delete cascade,
  foreign key (booked_activity_candidate_id, user_id)
    references semantic_private.booked_activity_candidates(id, user_id)
    on delete cascade,
  foreign key (hub_concept_id)
    references ontology.concepts(id) on delete restrict,
  constraint memories_snapshot_items_kind_check check (item_kind in (
    'hub', 'subhub', 'summary', 'assertion', 'representative',
    'scheduled_travel_candidate', 'booked_activity_candidate'
  )),
  constraint memories_snapshot_items_assertion_shape_check check (
    (item_kind in ('assertion', 'representative')
      and assertion_id is not null
      and scheduled_travel_candidate_id is null
      and booked_activity_candidate_id is null)
    or (item_kind = 'scheduled_travel_candidate'
      and assertion_id is null
      and scheduled_travel_candidate_id is not null
      and booked_activity_candidate_id is null)
    or (item_kind = 'booked_activity_candidate'
      and assertion_id is null
      and scheduled_travel_candidate_id is null
      and booked_activity_candidate_id is not null)
    or (item_kind in ('hub', 'subhub', 'summary')
      and assertion_id is null
      and scheduled_travel_candidate_id is null
      and booked_activity_candidate_id is null)
  ),
  constraint memories_snapshot_items_rank_check check (rank >= 0),
  constraint memories_snapshot_items_explicitness_check check (
    explicitness_rank between 0 and 3
  ),
  constraint memories_snapshot_items_specificity_check check (
    specificity between 0 and 1
  ),
  constraint memories_snapshot_items_affinity_check check (
    affinity_strength between 0 and 1
  ),
  constraint memories_snapshot_items_label_check check (
    char_length(display_label) between 1 and 240
  ),
  constraint memories_snapshot_items_no_raw_payload_check check (
    not (display_payload ?| array[
      'raw_observation', 'raw_calendar', 'ticket', 'itinerary',
      'observation_id'
    ])
  )
);

-- -------------------------------------------------------------------------
-- Directional dyads, interpretable alignment pairs, and validated facts.
-- -------------------------------------------------------------------------

create table if not exists semantic_private.dyad_runs (
  id uuid primary key default extensions.gen_random_uuid(),
  viewer_user_id uuid not null references auth.users(id) on delete cascade,
  subject_user_id uuid not null references auth.users(id) on delete cascade,
  viewer_revision bigint not null,
  subject_revision bigint not null,
  ontology_version_id uuid not null
    references ontology.versions(id) on delete restrict,
  ranker_model_id uuid not null
    references ontology.model_versions(id) on delete restrict,
  run_purpose text not null,
  input_hash text not null,
  status text not null default 'running',
  semantic_proximity double precision,
  comparability double precision,
  metrics jsonb not null default '{}'::jsonb,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  unique (id, viewer_user_id, subject_user_id),
  unique (
    viewer_user_id, subject_user_id, viewer_revision, subject_revision,
    ontology_version_id, ranker_model_id, run_purpose, input_hash
  ),
  constraint dyad_runs_distinct_users_check check (
    viewer_user_id <> subject_user_id
  ),
  constraint dyad_runs_revision_check check (
    viewer_revision >= 0 and subject_revision >= 0
  ),
  constraint dyad_runs_purpose_check check (
    run_purpose in ('bio', 'icebreaker', 'both')
  ),
  constraint dyad_runs_status_check check (
    status in ('running', 'succeeded', 'stale', 'failed')
  ),
  constraint dyad_runs_finish_check check (
    (status = 'running' and finished_at is null) or
    (status <> 'running' and finished_at is not null)
  ),
  constraint dyad_runs_proximity_check check (
    semantic_proximity is null or semantic_proximity between 0 and 1
  ),
  constraint dyad_runs_comparability_check check (
    comparability is null or comparability between 0 and 1
  )
);

create or replace function semantic_private.dyad_run_is_current(target_run_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select run.viewer_revision = coalesce(viewer_state.revision, 0)
       and run.subject_revision = coalesce(subject_state.revision, 0)
       and run.status in ('running', 'succeeded')
    from semantic_private.dyad_runs as run
    left join semantic_private.user_state_versions as viewer_state
      on viewer_state.user_id = run.viewer_user_id
    left join semantic_private.user_state_versions as subject_state
      on subject_state.user_id = run.subject_user_id
    where run.id = target_run_id
  ), false);
$$;

create or replace function semantic_private.guard_dyad_run_current()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  current_viewer_revision bigint;
  current_subject_revision bigint;
begin
  if new.status not in ('running', 'succeeded') then return new; end if;
  select revision into current_viewer_revision
  from semantic_private.user_state_versions where user_id = new.viewer_user_id;
  select revision into current_subject_revision
  from semantic_private.user_state_versions where user_id = new.subject_user_id;
  if new.viewer_revision <> coalesce(current_viewer_revision, 0)
     or new.subject_revision <> coalesce(current_subject_revision, 0) then
    raise exception 'dyad run requires both current user revisions';
  end if;
  return new;
end;
$$;

drop trigger if exists dyad_runs_guard_current on semantic_private.dyad_runs;
create trigger dyad_runs_guard_current
before insert or update of status, viewer_revision, subject_revision
on semantic_private.dyad_runs
for each row execute function semantic_private.guard_dyad_run_current();

create table if not exists semantic_private.dyad_alignment_pairs (
  id uuid primary key default extensions.gen_random_uuid(),
  dyad_run_id uuid not null,
  viewer_user_id uuid not null,
  subject_user_id uuid not null,
  viewer_assertion_id uuid not null,
  subject_assertion_id uuid not null,
  bridge_concept_id uuid not null,
  ontology_version_id uuid not null,
  graph_distance double precision not null,
  relation_distance double precision not null,
  embedding_distance double precision not null,
  transport_mass double precision not null,
  specificity double precision not null,
  information_value double precision not null,
  explanation_path jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  foreign key (dyad_run_id, viewer_user_id, subject_user_id)
    references semantic_private.dyad_runs(id, viewer_user_id, subject_user_id)
    on delete cascade,
  foreign key (viewer_assertion_id, viewer_user_id)
    references semantic_private.user_assertions(id, user_id) on delete cascade,
  foreign key (subject_assertion_id, subject_user_id)
    references semantic_private.user_assertions(id, user_id) on delete cascade,
  foreign key (ontology_version_id, bridge_concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict,
  constraint dyad_alignment_pairs_distance_check check (
    graph_distance between 0 and 1
    and relation_distance between 0 and 1
    and embedding_distance between 0 and 1
  ),
  constraint dyad_alignment_pairs_mass_check check (
    transport_mass > 0 and transport_mass <= 1
  ),
  constraint dyad_alignment_pairs_specificity_check check (
    specificity between 0 and 1 and information_value between 0 and 1
  ),
  constraint dyad_alignment_pairs_unique unique (
    dyad_run_id, viewer_assertion_id, subject_assertion_id, bridge_concept_id
  )
);

create or replace function semantic_private.guard_dyad_alignment_current()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  run_version uuid;
begin
  if not semantic_private.dyad_run_is_current(new.dyad_run_id) then
    raise exception 'dyad output requires both current user revisions';
  end if;
  select ontology_version_id into run_version
  from semantic_private.dyad_runs where id = new.dyad_run_id;
  if new.ontology_version_id is distinct from run_version then
    raise exception 'alignment ontology version must match its dyad run';
  end if;
  if not exists (
    select 1 from semantic_private.assertion_surface_permissions as permission
    where permission.assertion_id = new.viewer_assertion_id
      and permission.user_id = new.viewer_user_id
      and permission.surface = 'matching'
      and permission.can_select
  ) or not exists (
    select 1 from semantic_private.assertion_surface_permissions as permission
    where permission.assertion_id = new.subject_assertion_id
      and permission.user_id = new.subject_user_id
      and permission.surface = 'matching'
      and permission.can_select
  ) then
    raise exception 'dyad alignment requires matching permission on both assertions';
  end if;
  return new;
end;
$$;

drop trigger if exists dyad_alignment_pairs_guard_current
  on semantic_private.dyad_alignment_pairs;
create trigger dyad_alignment_pairs_guard_current
before insert or update on semantic_private.dyad_alignment_pairs
for each row execute function semantic_private.guard_dyad_alignment_current();

create table if not exists semantic_private.validated_surface_facts (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null,
  assertion_id uuid not null,
  ontology_version_id uuid not null
    references ontology.versions(id) on delete restrict,
  surface text not null,
  predicate_key text not null
    references ontology.relation_types(predicate_key) on delete restrict,
  display_label text not null,
  evidence_class text not null,
  confirmation_state text not null,
  may_name boolean not null default false,
  may_explain boolean not null default false,
  validator_model_id uuid not null
    references ontology.model_versions(id) on delete restrict,
  fact_version text not null,
  fact_payload jsonb not null default '{}'::jsonb,
  state text not null default 'candidate',
  created_at timestamptz not null default now(),
  unique (id, user_id),
  unique (assertion_id, surface, fact_version),
  foreign key (assertion_id, user_id)
    references semantic_private.user_assertions(id, user_id) on delete cascade,
  constraint validated_surface_facts_surface_check check (
    surface in ('bio', 'icebreaker')
  ),
  constraint validated_surface_facts_evidence_class_check check (
    evidence_class in (
      'explicit', 'ontology_inferred', 'calendar_derived', 'youtube_derived'
    )
  ),
  constraint validated_surface_facts_confirmation_check check (
    confirmation_state in ('inferred', 'user_confirmed', 'explicit_self_report')
  ),
  constraint validated_surface_facts_name_explain_check check (
    not may_explain or may_name
  ),
  constraint validated_surface_facts_calendar_public_check check (
    evidence_class <> 'calendar_derived' or (
      may_explain = false
      and (
        may_name = false or confirmation_state in (
          'user_confirmed', 'explicit_self_report'
        )
      )
    )
  ),
  constraint validated_surface_facts_no_raw_payload_check check (
    not (fact_payload ?| array[
      'raw_observation', 'raw_calendar', 'ticket', 'itinerary',
      'observation_id'
    ])
  ),
  constraint validated_surface_facts_state_check check (
    state in ('candidate', 'validated', 'retired')
  ),
  constraint validated_surface_facts_label_check check (
    char_length(display_label) between 1 and 240
  )
);

create or replace function semantic_private.guard_validated_surface_fact()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  assertion_predicate text;
  assertion_version uuid;
  permission semantic_private.assertion_surface_permissions%rowtype;
begin
  select predicate_key, created_ontology_version_id
  into assertion_predicate, assertion_version
  from semantic_private.user_assertions
  where id = new.assertion_id and user_id = new.user_id;
  if assertion_predicate is null
     or assertion_predicate is distinct from new.predicate_key
     or assertion_version is distinct from new.ontology_version_id then
    raise exception 'surface fact must preserve assertion predicate and version';
  end if;
  select * into permission
  from semantic_private.assertion_surface_permissions
  where assertion_id = new.assertion_id
    and user_id = new.user_id
    and surface = new.surface;
  if not found or not permission.can_select
     or (new.may_name and not permission.can_name)
     or (new.may_explain and not permission.can_explain) then
    raise exception 'surface fact exceeds assertion surface permission';
  end if;
  if new.evidence_class = 'youtube_derived' and (
       not semantic_private.assertion_has_youtube_evidence(new.assertion_id, new.user_id)
       or (new.may_name and not semantic_private.youtube_assertion_gate_allowed(
         new.assertion_id, new.user_id, new.surface
       ))
       or (new.may_explain and not semantic_private.youtube_assertion_gate_allowed(
         new.assertion_id, new.user_id, 'explanation'
       ))
     ) then
    raise exception 'YouTube-derived fact exceeds its approved run policy';
  end if;
  return new;
end;
$$;

drop trigger if exists validated_surface_facts_guard_permission
  on semantic_private.validated_surface_facts;
create trigger validated_surface_facts_guard_permission
before insert or update on semantic_private.validated_surface_facts
for each row execute function semantic_private.guard_validated_surface_fact();

-- -------------------------------------------------------------------------
-- Versioned bio variants.
-- -------------------------------------------------------------------------

create table if not exists semantic_private.bio_variants (
  id uuid primary key default extensions.gen_random_uuid(),
  dyad_run_id uuid not null,
  viewer_user_id uuid not null,
  subject_user_id uuid not null,
  renderer_model_id uuid not null
    references ontology.model_versions(id) on delete restrict,
  variant_version text not null,
  state text not null default 'draft',
  stable_text text not null,
  personalized_text text,
  render_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  finalized_at timestamptz,
  unique (id, viewer_user_id, subject_user_id),
  unique (id, subject_user_id),
  unique (dyad_run_id, renderer_model_id, variant_version),
  foreign key (dyad_run_id, viewer_user_id, subject_user_id)
    references semantic_private.dyad_runs(id, viewer_user_id, subject_user_id)
    on delete cascade,
  constraint bio_variants_state_check check (
    state in ('draft', 'ready', 'stale', 'retired')
  ),
  constraint bio_variants_finalize_check check (
    (state = 'draft' and finalized_at is null) or
    (state <> 'draft' and finalized_at is not null)
  ),
  constraint bio_variants_stable_text_check check (
    char_length(stable_text) between 1 and 1200
  ),
  constraint bio_variants_personalized_text_check check (
    personalized_text is null or char_length(personalized_text) between 1 and 600
  ),
  constraint bio_variants_no_raw_payload_check check (
    not (render_payload ?| array[
      'raw_observation', 'raw_calendar', 'ticket', 'itinerary',
      'observation_id'
    ])
  )
);

create table if not exists semantic_private.bio_variant_facts (
  bio_variant_id uuid not null,
  surface_fact_id uuid not null,
  subject_user_id uuid not null,
  clause_role text not null,
  rank integer not null,
  created_at timestamptz not null default now(),
  primary key (bio_variant_id, surface_fact_id),
  foreign key (bio_variant_id, subject_user_id)
    references semantic_private.bio_variants(id, subject_user_id) on delete cascade,
  foreign key (surface_fact_id, subject_user_id)
    references semantic_private.validated_surface_facts(id, user_id) on delete restrict,
  constraint bio_variant_facts_clause_role_check check (
    clause_role in ('stable', 'personalized')
  ),
  constraint bio_variant_facts_rank_check check (rank >= 0),
  constraint bio_variant_facts_rank_unique unique (bio_variant_id, rank)
);

create unique index if not exists bio_variant_one_personalized_fact_idx
  on semantic_private.bio_variant_facts (bio_variant_id)
  where clause_role = 'personalized';

create or replace function semantic_private.guard_bio_variant_ready()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  invalid_fact_count integer;
  fact_count integer;
begin
  if new.state <> 'ready' then return new; end if;
  if not semantic_private.dyad_run_is_current(new.dyad_run_id) then
    raise exception 'ready bio requires both current user revisions';
  end if;
  select count(*), count(*) filter (
    where fact.surface <> 'bio'
       or fact.state <> 'validated'
       or not fact.may_name
       or fact.user_id <> new.subject_user_id
  ) into fact_count, invalid_fact_count
  from semantic_private.bio_variant_facts as link
  join semantic_private.validated_surface_facts as fact
    on fact.id = link.surface_fact_id
   and fact.user_id = link.subject_user_id
  where link.bio_variant_id = new.id;
  if fact_count < 1 or invalid_fact_count > 0 then
    raise exception 'ready bio requires validated nameable subject facts';
  end if;
  return new;
end;
$$;

drop trigger if exists bio_variants_guard_ready on semantic_private.bio_variants;
create trigger bio_variants_guard_ready
before insert or update of state, dyad_run_id on semantic_private.bio_variants
for each row execute function semantic_private.guard_bio_variant_ready();

-- -------------------------------------------------------------------------
-- Match-authorized deterministic icebreaker frames.
-- This is a server-maintained authorization mirror, not a client write API.
-- -------------------------------------------------------------------------

create table if not exists semantic_private.match_authorizations (
  id uuid primary key default extensions.gen_random_uuid(),
  match_id uuid not null unique,
  participant_a_user_id uuid not null
    references auth.users(id) on delete cascade,
  participant_b_user_id uuid not null
    references auth.users(id) on delete cascade,
  authorization_state text not null default 'active',
  authorized_at timestamptz not null default now(),
  revoked_at timestamptz,
  source_version text not null,
  created_at timestamptz not null default now(),
  unique (id, participant_a_user_id, participant_b_user_id),
  constraint match_authorizations_distinct_users_check check (
    participant_a_user_id <> participant_b_user_id
  ),
  constraint match_authorizations_state_check check (
    authorization_state in ('active', 'revoked', 'expired')
  ),
  constraint match_authorizations_revocation_check check (
    (authorization_state = 'active' and revoked_at is null) or
    (authorization_state <> 'active' and revoked_at is not null)
  )
);

create table if not exists semantic_private.icebreaker_frames (
  id uuid primary key default extensions.gen_random_uuid(),
  match_authorization_id uuid not null,
  dyad_run_id uuid not null,
  viewer_user_id uuid not null,
  subject_user_id uuid not null,
  bridge_concept_id uuid not null,
  ontology_version_id uuid not null,
  renderer_model_id uuid not null
    references ontology.model_versions(id) on delete restrict,
  bridge_mode text not null,
  template_version text not null,
  frame_payload jsonb not null,
  rendered_text text,
  state text not null default 'draft',
  created_at timestamptz not null default now(),
  finalized_at timestamptz,
  unique (id, viewer_user_id, subject_user_id),
  unique (match_authorization_id, dyad_run_id, template_version),
  foreign key (match_authorization_id)
    references semantic_private.match_authorizations(id) on delete cascade,
  foreign key (dyad_run_id, viewer_user_id, subject_user_id)
    references semantic_private.dyad_runs(id, viewer_user_id, subject_user_id)
    on delete cascade,
  foreign key (ontology_version_id, bridge_concept_id)
    references ontology.concept_revisions(ontology_version_id, concept_id)
    on delete restrict,
  constraint icebreaker_frames_bridge_mode_check check (bridge_mode in (
    'both_like', 'common_ground', 'shared_thread', 'conversation_topic'
  )),
  constraint icebreaker_frames_state_check check (
    state in ('draft', 'ready', 'stale', 'revoked')
  ),
  constraint icebreaker_frames_finalize_check check (
    (state = 'draft' and finalized_at is null) or
    (state <> 'draft' and finalized_at is not null)
  ),
  constraint icebreaker_frames_no_raw_payload_check check (
    not (frame_payload ?| array[
      'raw_observation', 'raw_calendar', 'ticket', 'itinerary',
      'observation_id'
    ])
  ),
  constraint icebreaker_frames_rendered_text_check check (
    rendered_text is null or char_length(rendered_text) between 1 and 800
  )
);

create table if not exists semantic_private.icebreaker_frame_facts (
  icebreaker_frame_id uuid not null,
  surface_fact_id uuid not null,
  fact_user_id uuid not null,
  fact_side text not null,
  created_at timestamptz not null default now(),
  primary key (icebreaker_frame_id, surface_fact_id),
  foreign key (icebreaker_frame_id)
    references semantic_private.icebreaker_frames(id) on delete cascade,
  foreign key (surface_fact_id, fact_user_id)
    references semantic_private.validated_surface_facts(id, user_id) on delete restrict,
  constraint icebreaker_frame_facts_side_check check (
    fact_side in ('viewer', 'subject')
  ),
  constraint icebreaker_frame_facts_one_per_side unique (
    icebreaker_frame_id, fact_side
  )
);

create or replace function semantic_private.guard_icebreaker_frame_ready()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  auth_state text;
  auth_a uuid;
  auth_b uuid;
  run_version uuid;
  viewer_fact semantic_private.validated_surface_facts%rowtype;
  subject_fact semantic_private.validated_surface_facts%rowtype;
begin
  if new.state <> 'ready' then return new; end if;
  if not semantic_private.dyad_run_is_current(new.dyad_run_id) then
    raise exception 'ready icebreaker requires both current user revisions';
  end if;
  select authorization_state, participant_a_user_id, participant_b_user_id
  into auth_state, auth_a, auth_b
  from semantic_private.match_authorizations where id = new.match_authorization_id;
  if auth_state is distinct from 'active'
     or not (
       (auth_a = new.viewer_user_id and auth_b = new.subject_user_id)
       or (auth_a = new.subject_user_id and auth_b = new.viewer_user_id)
     ) then
    raise exception 'icebreaker requires an active directional match authorization';
  end if;
  select ontology_version_id into run_version
  from semantic_private.dyad_runs where id = new.dyad_run_id;
  if new.ontology_version_id is distinct from run_version then
    raise exception 'icebreaker ontology version must match its dyad run';
  end if;
  select fact.* into viewer_fact
  from semantic_private.icebreaker_frame_facts as link
  join semantic_private.validated_surface_facts as fact
    on fact.id = link.surface_fact_id and fact.user_id = link.fact_user_id
  where link.icebreaker_frame_id = new.id and link.fact_side = 'viewer';
  select fact.* into subject_fact
  from semantic_private.icebreaker_frame_facts as link
  join semantic_private.validated_surface_facts as fact
    on fact.id = link.surface_fact_id and fact.user_id = link.fact_user_id
  where link.icebreaker_frame_id = new.id and link.fact_side = 'subject';
  if viewer_fact.id is null or subject_fact.id is null
     or viewer_fact.user_id is distinct from new.viewer_user_id
     or subject_fact.user_id is distinct from new.subject_user_id
     or viewer_fact.surface <> 'icebreaker'
     or subject_fact.surface <> 'icebreaker'
     or viewer_fact.state <> 'validated'
     or subject_fact.state <> 'validated'
     or not viewer_fact.may_name
     or not subject_fact.may_name then
    raise exception 'ready icebreaker requires one validated nameable fact per side';
  end if;
  if new.bridge_mode = 'both_like' and (
    viewer_fact.predicate_key <> 'affinity_to'
    or subject_fact.predicate_key <> 'affinity_to'
    or viewer_fact.confirmation_state not in ('user_confirmed', 'explicit_self_report')
    or subject_fact.confirmation_state not in ('user_confirmed', 'explicit_self_report')
  ) then
    raise exception 'both_like requires two confirmed affinity facts';
  end if;
  return new;
end;
$$;

drop trigger if exists icebreaker_frames_guard_ready
  on semantic_private.icebreaker_frames;
create trigger icebreaker_frames_guard_ready
before insert or update of state, dyad_run_id, match_authorization_id
on semantic_private.icebreaker_frames
for each row execute function semantic_private.guard_icebreaker_frame_ready();

-- Any user edit invalidates all snapshots whose two-sided revision contract is
-- no longer current. Physical history remains for replay/audit, but stale rows
-- are never eligible for ready product surfaces.
create or replace function semantic_private.invalidate_product_outputs_on_revision()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.revision is not distinct from old.revision then return new; end if;
  update semantic_private.memories_snapshots
  set state = 'stale', finished_at = coalesce(finished_at, now())
  where user_id = new.user_id
    and input_revision <> new.revision
    and state in ('building', 'ready');
  update semantic_private.dyad_runs
  set status = 'stale', finished_at = coalesce(finished_at, now())
  where (viewer_user_id = new.user_id or subject_user_id = new.user_id)
    and status in ('running', 'succeeded')
    and (
      (viewer_user_id = new.user_id and viewer_revision <> new.revision) or
      (subject_user_id = new.user_id and subject_revision <> new.revision)
    );
  update semantic_private.bio_variants as bio
  set state = 'stale', finalized_at = coalesce(finalized_at, now())
  where state in ('draft', 'ready')
    and exists (
      select 1 from semantic_private.dyad_runs as run
      where run.id = bio.dyad_run_id and run.status = 'stale'
    );
  update semantic_private.icebreaker_frames as frame
  set state = 'stale', finalized_at = coalesce(finalized_at, now())
  where state in ('draft', 'ready')
    and exists (
      select 1 from semantic_private.dyad_runs as run
      where run.id = frame.dyad_run_id and run.status = 'stale'
    );
  return new;
end;
$$;

drop trigger if exists user_state_versions_invalidate_product_outputs
  on semantic_private.user_state_versions;
create trigger user_state_versions_invalidate_product_outputs
after update of revision on semantic_private.user_state_versions
for each row execute function semantic_private.invalidate_product_outputs_on_revision();

-- Replace shallow top-level checks with one recursive, size-bounded,
-- handler-whitelisted payload contract on every v0.2 classification,
-- derivation, and presentation JSON column.
alter table ontology.youtube_channel_resolutions
  drop constraint if exists youtube_channel_resolutions_safe_evidence_check,
  add constraint youtube_channel_resolutions_safe_evidence_check check (
    semantic_private.jsonb_payload_is_safe(evidence, 4096, array[
      'resolver_version', 'review_reference', 'identity_signal_types',
      'role_signal_types', 'catalog_match_kind', 'evidence_count',
      'reason_codes'
    ]::text[])
  );
alter table semantic_private.calendar_event_classifications
  drop constraint if exists calendar_classifications_safe_payload_check,
  add constraint calendar_classifications_safe_payload_check check (
    semantic_private.jsonb_payload_is_safe(feature_snapshot, 8192, array[
      'classifier_version', 'reason_codes', 'flags', 'ownership_state',
      'event_class', 'vendor_class', 'parse_quality', 'artifact_type'
    ]::text[])
  );
alter table semantic_private.travel_segments
  drop constraint if exists travel_segments_safe_payload_check,
  add constraint travel_segments_safe_payload_check check (
    semantic_private.jsonb_payload_is_safe(extraction_payload, 8192, array[
      'extractor_version', 'quality_factors', 'reason_codes', 'parse_method'
    ]::text[])
  );
alter table semantic_private.travel_journeys
  drop constraint if exists travel_journeys_safe_payload_check,
  add constraint travel_journeys_safe_payload_check check (
    semantic_private.jsonb_payload_is_safe(derivation_payload, 8192, array[
      'builder_version', 'quality_factors', 'reason_codes', 'segment_count',
      'terminal_fraction', 'connection_policy'
    ]::text[])
  );
alter table semantic_private.recurring_place_candidates
  drop constraint if exists recurring_place_candidates_safe_payload_check,
  add constraint recurring_place_candidates_safe_payload_check check (
    semantic_private.jsonb_payload_is_safe(derivation_payload, 8192, array[
      'scorer_version', 'quality_factors', 'reason_codes',
      'recurrence_score', 'terminal_fraction', 'return_pair_count'
    ]::text[])
  );
alter table semantic_private.scheduled_travel_candidates
  drop constraint if exists scheduled_travel_candidates_no_raw_payload_check,
  add constraint scheduled_travel_candidates_no_raw_payload_check check (
    semantic_private.jsonb_payload_is_safe(display_payload, 4096, array[
      'template_key', 'wording_version', 'predicate_label', 'place_label',
      'source_badges'
    ]::text[])
  );
alter table semantic_private.booked_activity_candidates
  drop constraint if exists booked_activity_candidates_safe_payload_check,
  add constraint booked_activity_candidates_safe_payload_check check (
    semantic_private.jsonb_payload_is_safe(display_payload, 4096, array[
      'template_key', 'wording_version', 'predicate_label', 'target_label',
      'place_label', 'source_badges'
    ]::text[])
  );
alter table semantic_private.memories_snapshots
  drop constraint if exists memories_snapshots_safe_metrics_check,
  add constraint memories_snapshots_safe_metrics_check check (
    semantic_private.jsonb_payload_is_safe(metrics, 4096, array[
      'item_count', 'group_count', 'build_duration_ms', 'abstained_count'
    ]::text[])
  );
alter table semantic_private.memories_snapshot_items
  drop constraint if exists memories_snapshot_items_no_raw_payload_check,
  add constraint memories_snapshot_items_no_raw_payload_check check (
    semantic_private.jsonb_payload_is_safe(display_payload, 4096, array[
      'template_key', 'wording_version', 'predicate_label', 'place_label',
      'target_label', 'source_badges', 'badges', 'subtitle'
    ]::text[])
  );
alter table semantic_private.dyad_runs
  drop constraint if exists dyad_runs_safe_metrics_check,
  add constraint dyad_runs_safe_metrics_check check (
    semantic_private.jsonb_payload_is_safe(metrics, 4096, array[
      'iteration_count', 'transported_mass', 'unmatched_mass',
      'coverage_overlap', 'duration_ms'
    ]::text[])
  );
alter table semantic_private.dyad_alignment_pairs
  drop constraint if exists dyad_alignment_pairs_safe_explanation_check,
  add constraint dyad_alignment_pairs_safe_explanation_check check (
    semantic_private.jsonb_payload_is_safe(explanation_path, 8192, array[
      'path_type', 'predicate_path', 'concept_path', 'relation_types',
      'cost_components'
    ]::text[])
  );
alter table semantic_private.validated_surface_facts
  drop constraint if exists validated_surface_facts_no_raw_payload_check,
  add constraint validated_surface_facts_no_raw_payload_check check (
    semantic_private.jsonb_payload_is_safe(fact_payload, 4096, array[
      'template_key', 'wording_version', 'predicate_label', 'concept_label',
      'source_badges', 'license'
    ]::text[])
  );
alter table semantic_private.bio_variants
  drop constraint if exists bio_variants_no_raw_payload_check,
  add constraint bio_variants_no_raw_payload_check check (
    semantic_private.jsonb_payload_is_safe(render_payload, 4096, array[
      'template_key', 'wording_version', 'clause_ids', 'renderer_version'
    ]::text[])
  );
alter table semantic_private.icebreaker_frames
  drop constraint if exists icebreaker_frames_no_raw_payload_check,
  add constraint icebreaker_frames_no_raw_payload_check check (
    semantic_private.jsonb_payload_is_safe(frame_payload, 8192, array[
      'template_key', 'wording_version', 'bridge_label', 'left_clause',
      'right_clause', 'license', 'renderer_version'
    ]::text[])
  );

-- -------------------------------------------------------------------------
-- Default-deny RLS and explicit service-worker access. No client policy is
-- created, so anon/authenticated cannot read or mutate these internal tables.
-- -------------------------------------------------------------------------

alter table ontology.youtube_channels enable row level security;
alter table ontology.youtube_channel_resolutions enable row level security;
alter table ontology.youtube_policy_approvals enable row level security;
alter table semantic_private.youtube_run_policies enable row level security;
alter table semantic_private.youtube_observation_channels enable row level security;
alter table semantic_private.calendar_event_classifications enable row level security;
alter table semantic_private.travel_segments enable row level security;
alter table semantic_private.travel_segment_sources enable row level security;
alter table semantic_private.travel_journeys enable row level security;
alter table semantic_private.travel_journey_segments enable row level security;
alter table semantic_private.recurring_place_candidates enable row level security;
alter table semantic_private.scheduled_travel_candidates enable row level security;
alter table semantic_private.booked_activity_candidates enable row level security;
alter table semantic_private.assertion_surface_permissions enable row level security;
alter table semantic_private.memories_snapshots enable row level security;
alter table semantic_private.memories_snapshot_items enable row level security;
alter table semantic_private.dyad_runs enable row level security;
alter table semantic_private.dyad_alignment_pairs enable row level security;
alter table semantic_private.validated_surface_facts enable row level security;
alter table semantic_private.bio_variants enable row level security;
alter table semantic_private.bio_variant_facts enable row level security;
alter table semantic_private.match_authorizations enable row level security;
alter table semantic_private.icebreaker_frames enable row level security;
alter table semantic_private.icebreaker_frame_facts enable row level security;

revoke all on table ontology.youtube_channels
  from public, anon, authenticated, service_role;
revoke all on table ontology.youtube_channel_resolutions
  from public, anon, authenticated, service_role;
revoke all on table ontology.youtube_policy_approvals
  from public, anon, authenticated, service_role;
revoke all on table semantic_private.youtube_run_policies,
  semantic_private.youtube_observation_channels,
  semantic_private.calendar_event_classifications,
  semantic_private.travel_segments,
  semantic_private.travel_segment_sources,
  semantic_private.travel_journeys,
  semantic_private.travel_journey_segments,
  semantic_private.recurring_place_candidates,
  semantic_private.scheduled_travel_candidates,
  semantic_private.booked_activity_candidates,
  semantic_private.assertion_surface_permissions,
  semantic_private.memories_snapshots,
  semantic_private.memories_snapshot_items,
  semantic_private.dyad_runs,
  semantic_private.dyad_alignment_pairs,
  semantic_private.validated_surface_facts,
  semantic_private.bio_variants,
  semantic_private.bio_variant_facts,
  semantic_private.match_authorizations,
  semantic_private.icebreaker_frames,
  semantic_private.icebreaker_frame_facts
from public, anon, authenticated, service_role;

grant usage on schema ontology, semantic_private to service_role;
grant select, insert, update on table
  ontology.youtube_channels,
  ontology.youtube_channel_resolutions,
  ontology.youtube_policy_approvals
to service_role;
grant select, insert, update on table
  semantic_private.youtube_run_policies,
  semantic_private.youtube_observation_channels,
  semantic_private.calendar_event_classifications,
  semantic_private.travel_segments,
  semantic_private.travel_segment_sources,
  semantic_private.travel_journeys,
  semantic_private.travel_journey_segments,
  semantic_private.recurring_place_candidates,
  semantic_private.scheduled_travel_candidates,
  semantic_private.booked_activity_candidates,
  semantic_private.assertion_surface_permissions,
  semantic_private.memories_snapshots,
  semantic_private.memories_snapshot_items,
  semantic_private.dyad_runs,
  semantic_private.dyad_alignment_pairs,
  semantic_private.validated_surface_facts,
  semantic_private.bio_variants,
  semantic_private.bio_variant_facts,
  semantic_private.match_authorizations,
  semantic_private.icebreaker_frames,
  semantic_private.icebreaker_frame_facts
to service_role;

revoke all on function semantic_private.fill_score_quality_columns() from public;
revoke all on function semantic_private.recency_audit_is_valid(
  double precision, double precision, text, text, text, text
) from public;
revoke all on function semantic_private.pin_recency_to_semantic_run() from public;
revoke all on function semantic_private.inherit_mapping_recency() from public;
revoke all on function semantic_private.jsonb_tree_has_no_private_keys(jsonb, integer) from public;
revoke all on function semantic_private.jsonb_payload_is_safe(jsonb, integer, text[]) from public;
revoke all on function semantic_private.guard_youtube_run_policy() from public;
revoke all on function semantic_private.initialize_youtube_run_policy() from public;
revoke all on function semantic_private.youtube_run_gate_allowed(uuid, text) from public;
revoke all on function semantic_private.guard_youtube_mapping_fusion() from public;
revoke all on function semantic_private.guard_calendar_observation_mapping() from public;
revoke all on function semantic_private.initialize_assertion_surface_permissions() from public;
revoke all on function semantic_private.assertion_has_calendar_evidence(uuid, uuid) from public;
revoke all on function semantic_private.guard_calendar_surface_permission() from public;
revoke all on function semantic_private.clear_calendar_permissions_on_downgrade() from public;
revoke all on function semantic_private.invalidate_on_matching_permission_revocation() from public;
revoke all on function semantic_private.guard_youtube_channel_relation() from public;
revoke all on function semantic_private.guard_travel_segment_classification() from public;
revoke all on function semantic_private.guard_travel_segment_source() from public;
revoke all on function semantic_private.initialize_travel_segment_primary_source() from public;
revoke all on function semantic_private.guard_travel_journey_segment_role() from public;
revoke all on function semantic_private.guard_booked_activity_candidate() from public;
revoke all on function semantic_private.guard_scheduled_travel_journey_terminal() from public;
revoke all on function semantic_private.guard_calendar_assertion_evidence() from public;
revoke all on function semantic_private.assertion_has_youtube_evidence(uuid, uuid) from public;
revoke all on function semantic_private.youtube_assertion_gate_allowed(uuid, uuid, text) from public;
revoke all on function semantic_private.guard_youtube_surface_permission() from public;
revoke all on function semantic_private.guard_youtube_assertion_evidence() from public;
revoke all on function semantic_private.guard_assertion_exposure_permission() from public;
revoke all on function ontology.guard_youtube_channel_resolution_role() from public;
revoke all on function semantic_private.guard_memories_snapshot_current() from public;
revoke all on function semantic_private.dyad_run_is_current(uuid) from public;
revoke all on function semantic_private.guard_dyad_run_current() from public;
revoke all on function semantic_private.guard_dyad_alignment_current() from public;
revoke all on function semantic_private.guard_validated_surface_fact() from public;
revoke all on function semantic_private.guard_bio_variant_ready() from public;
revoke all on function semantic_private.guard_icebreaker_frame_ready() from public;
revoke all on function semantic_private.invalidate_product_outputs_on_revision() from public;

grant execute on function
  semantic_private.recency_audit_is_valid(
    double precision, double precision, text, text, text, text
  ),
  semantic_private.jsonb_tree_has_no_private_keys(jsonb, integer),
  semantic_private.jsonb_payload_is_safe(jsonb, integer, text[]),
  semantic_private.youtube_run_gate_allowed(uuid, text),
  semantic_private.assertion_has_calendar_evidence(uuid, uuid),
  semantic_private.assertion_has_youtube_evidence(uuid, uuid),
  semantic_private.youtube_assertion_gate_allowed(uuid, uuid, text),
  semantic_private.dyad_run_is_current(uuid)
to service_role;

commit;
