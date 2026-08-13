-- 0133 — Outlook Calendar becomes a source, and the calendar list stops being
--        written out five times.
--
-- **The registration is the small half; the five literals are the reason this
-- migration exists.** Six functions decide how a calendar observation is
-- treated, and five of them name `apple_calendar` and `google_calendar` as a
-- literal `in (...)` list:
--
--   assertion_has_calendar_evidence            — is this claim calendar-backed
--   guard_calendar_assertion_evidence          — calendar evidence may not sit
--                                                under a public surface grant
--   guard_calendar_classification_current_v03  — the pinned classifier lane
--   guard_calendar_observation_mapping         — no generic mapping lane
--   guard_private_source_generic_lane_v03      — no mention or feedback lane
--   private_observation_projection_is_valid_v03 — the sanitised shape, twice
--
-- **Four of those six are prohibitions, so a source missing from the list is
-- not merely unhandled — it is permitted.** Adding `outlook_calendar` to
-- `sources` and stopping there would have produced a calendar whose events may
-- enter the generic mention lane, whose observations may carry an unsanitised
-- payload, and whose evidence may be named on a public surface: three
-- protections the other two calendars have, silently absent on the third, with
-- nothing anywhere reporting it. That is the failure this file is arranged
-- around, and it is why the list becomes a function rather than gaining a third
-- string in five places.
--
-- `is_private_calendar_source` and `is_private_lane_source` are **pure literal
-- arrays, deliberately not table lookups.** `private_observation_projection_is_
-- valid_v03` is `immutable` and backs a check constraint on
-- `semantic_private.observations`; a helper that read `sources` could not be
-- immutable, and making the projection `stable` to accommodate it would mean
-- dropping and re-adding that constraint, which re-validates every observation
-- row. One place to edit is the whole gain here — reading it from a table would
-- also let a row in `sources` quietly change what is enforced.
--
-- **Nothing sends Outlook rows anywhere yet.** `OutlookCalendarDistiller`
-- writes to `distilled_records` only; `AppConfig.semanticIngestionSources` does
-- not list it. This migration is what has to be true *before* it can be added,
-- not a consequence of it having been.
--
-- **No behaviour changes for the existing two.** The helpers answer exactly
-- what the literals answered for `apple_calendar`, `google_calendar` and
-- `healthkit`; the only new answer is for `outlook_calendar`, which had no rows
-- and could have none.

begin;

-- ---------------------------------------------------------------------------
-- The list, once.
-- ---------------------------------------------------------------------------

create or replace function semantic_private.is_private_calendar_source(
  checked_source_code text
) returns boolean
language sql
immutable
set search_path to ''
as $$
  -- Every calendar connector. A calendar is private in a way a music library
  -- is not: the titles are other people's names, addresses and medical
  -- appointments, which is why these rows are classified before they are
  -- evidence and never transcribed.
  select checked_source_code = any (array[
    'apple_calendar', 'google_calendar', 'outlook_calendar'
  ]);
$$;

create or replace function semantic_private.is_private_lane_source(
  checked_source_code text
) returns boolean
language sql
immutable
set search_path to ''
as $$
  -- The calendars plus HealthKit: sources whose observations may never enter
  -- the generic mention or feedback lanes, and whose projections must be a
  -- classifier's sanitised output rather than a transcription.
  select semantic_private.is_private_calendar_source(checked_source_code)
      or checked_source_code = 'healthkit';
$$;

-- ---------------------------------------------------------------------------
-- The source itself.
-- ---------------------------------------------------------------------------

-- **Same `independence_group` as the other two, and that is a real decision.**
-- A person's Outlook calendar and their Apple calendar are frequently the same
-- diary reached two ways — an Exchange account added in iOS Settings arrives
-- through EventKit as well as through Graph — so two calendars agreeing is one
-- witness, not two. `minimum_independence_groups >= 2` would otherwise be
-- satisfiable by a duplicate.
--
-- **`booked` is weighted here even though this connector cannot produce it.**
-- `Calendars.ReadBasic` returns no organiser and no url, so
-- `OutlookCalendarDistiller` never stamps `booked=1` and `SemanticSource` maps
-- its events to `scheduled` alone. The weight is carried anyway so the row
-- matches its siblings: the day a broader scope is justified, the vocabulary
-- is already right, and a weight for an action nobody sends costs nothing.
-- Both are 0.0 regardless — the calendar projection pins `action_weight` at
-- exactly zero, which is what makes a calendar a candidate lane rather than a
-- scoring one.
insert into semantic_private.sources (
  source_code, provider, evidence_channel, independence_group,
  online_resolution_policy, default_reliability, action_weights, active
) values (
  'outlook_calendar', 'microsoft', 'calendar', 'calendar',
  'disabled_private', 0.9,
  jsonb_build_object(
    'scheduled', 0.9, 'booked', 0.0, 'cancelled', 0.0, 'entered_by_user', 0.0
  ),
  true
)
on conflict (source_code) do nothing;

insert into semantic_private.connector_record_source_matrix (
  connector_source_code, record_source_code, rationale
) values (
  'outlook_calendar', 'outlook_calendar',
  'a connector may always deliver its own records'
)
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- The six, rewritten against the helpers.
-- ---------------------------------------------------------------------------
--
-- Bodies are otherwise verbatim from the deployed definitions. Signatures are
-- unchanged, so `create or replace` replaces rather than overloads — the trap
-- `0026`/`0027` and `0064` were each paid for. Replacing the body of a function
-- backing a check constraint does **not** re-validate existing rows, which is
-- correct here: the change only widens what is accepted, so every stored row
-- that passed still passes.

create or replace function semantic_private.assertion_has_calendar_evidence(
  target_assertion_id uuid, target_user_id uuid
) returns boolean
language sql
stable
set search_path to ''
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
      and semantic_private.is_private_calendar_source(observation.source_code)
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

create or replace function semantic_private.guard_calendar_assertion_evidence()
returns trigger
language plpgsql
set search_path to ''
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
  if not semantic_private.is_private_calendar_source(source_code_value) then
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

create or replace function semantic_private.guard_calendar_observation_mapping()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if exists (
    select 1
    from semantic_private.observations as observation
    where observation.id = new.observation_id
      and observation.user_id = new.user_id
      and semantic_private.is_private_calendar_source(observation.source_code)
  ) then
    raise exception 'Calendar observations cannot enter generic observation_mappings';
  end if;
  return new;
end;
$$;

create or replace function semantic_private.guard_private_source_generic_lane_v03()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if exists (
    select 1
    from semantic_private.observations as observation
    where observation.id = new.observation_id
      and observation.user_id = new.user_id
      and semantic_private.is_private_lane_source(observation.source_code)
  ) then
    raise exception 'private source observations cannot enter generic mention or feedback lanes';
  end if;
  return new;
end;
$$;

create or replace function semantic_private.guard_calendar_classification_current_v03()
returns trigger
language plpgsql
set search_path to ''
as $$
declare
  pinned_classifier_version text;
  controlled_artifact_type text;
begin
  select classifier.version into pinned_classifier_version
  from ontology.model_versions as classifier
  where classifier.id = new.classifier_model_id
    and classifier.model_role = 'calendar_classifier';
  if pinned_classifier_version is null then
    raise exception 'Calendar classification requires a registered classifier';
  end if;
  if coalesce(
       current_setting('written.calendar_v03_sanitizing', true), '0'
     ) <> '1' and not exists (
    select 1
    from semantic_private.observations as observation
    join semantic_private.user_state_versions as state
      on state.user_id = observation.user_id
     and state.revision = new.input_revision
    join ontology.model_versions as classifier
      on classifier.id = new.classifier_model_id
     and classifier.model_role = 'calendar_classifier'
     and classifier.status = 'active'
    join ontology.versions as version
      on version.id = new.ontology_version_id
     and version.status = 'published'
    where observation.id = new.observation_id
      and observation.user_id = new.user_id
      and semantic_private.is_private_calendar_source(observation.source_code)
      and observation.lifecycle_state = 'active'
  ) then
    raise exception 'Calendar classification must use the current revision, published ontology, and active classifier';
  end if;
  controlled_artifact_type := case
    when new.event_class = 'travel_itinerary' then 'travel_itinerary'
    when new.event_class = 'commercial_reservation' then 'commercial_reservation'
    when new.event_class = 'public_ticketed_event' then 'public_ticket'
    when new.disposition = 'review' then 'unknown_review'
    else 'private_excluded'
  end;
  new.feature_snapshot := jsonb_build_object(
    'classifier_version', pinned_classifier_version,
    'event_class', new.event_class,
    'disposition', new.disposition,
    'reason_codes', jsonb_build_array(
      'calendar_v03_' || new.event_class || '_' || new.disposition
    ),
    'artifact_type', controlled_artifact_type
  );
  return new;
end;
$$;

create or replace function semantic_private.private_observation_projection_is_valid_v03(
  checked_source_code text, checked_data_type text,
  checked_observation_kind text, checked_action_type text,
  checked_occurred_at timestamp with time zone,
  checked_source_item_hmac text, checked_record_fingerprint text,
  checked_content_lineage_hmac text, checked_session_hmac text,
  checked_payload_schema_version text, checked_normalized_payload jsonb,
  checked_raw_blob_ref text, checked_field_quality double precision,
  checked_action_weight double precision, checked_privacy_class text,
  checked_allow_external_resolution boolean, checked_lifecycle_state text,
  checked_exclusion_code text,
  checked_excluded_at timestamp with time zone
) returns boolean
language plpgsql
immutable
set search_path to ''
as $$
declare
  classification_state text;
  artifact_type text;
  candidate_id text;
  controlled_label text;
  coverage_state text;
  category_id text;
  channel_id text;
  subscriber_count text;
begin
  if checked_source_code = 'youtube' then
    if checked_normalized_payload is null
       or jsonb_typeof(checked_normalized_payload) <> 'object'
       or octet_length(checked_normalized_payload::text) > 2048
       or checked_payload_schema_version <> 'youtube-v03'
       or checked_observation_kind <> 'provider_labels'
       or checked_privacy_class <> 'public_catalog'
       or checked_raw_blob_ref is not null
       or checked_session_hmac is not null
       or checked_normalized_payload ->> 'schema_version' <> 'youtube-v03'
       or checked_normalized_payload ->> 'record_kind' <> 'youtube_labels' then
      return false;
    end if;

    -- Closed by subtraction: anything not named here makes the payload
    -- non-empty and the projection invalid.
    if (checked_normalized_payload
        - 'schema_version' - 'record_kind'
        - 'topics' - 'tags' - 'category_id' - 'channel_id'
        - 'subscriber_count') <> '{}'::jsonb then
      return false;
    end if;

    -- **A topic has no space in it and that is the whole guard.** The distiller
    -- stores the last path component of a Wikipedia URL, so `Lifestyle_(sociology)`
    -- and `Role-playing_video_game` pass while any sentence fails.
    if checked_normalized_payload ? 'topics' then
      if jsonb_typeof(checked_normalized_payload -> 'topics') <> 'array'
         or jsonb_array_length(checked_normalized_payload -> 'topics') > 24
         or exists (
           select 1
           from jsonb_array_elements(checked_normalized_payload -> 'topics') as t
           where jsonb_typeof(t) <> 'string'
              or t #>> '{}' !~ '^[A-Za-z0-9_()''.\-]{1,80}$'
         ) then
        return false;
      end if;
    end if;

    -- Uploader tags are free text by nature, so they are bounded rather than
    -- patterned: twelve items, sixty characters, no control characters.
    if checked_normalized_payload ? 'tags' then
      if jsonb_typeof(checked_normalized_payload -> 'tags') <> 'array'
         or jsonb_array_length(checked_normalized_payload -> 'tags') > 12
         or exists (
           select 1
           from jsonb_array_elements(checked_normalized_payload -> 'tags') as t
           where jsonb_typeof(t) <> 'string'
              or char_length(t #>> '{}') not between 1 and 60
              or t #>> '{}' ~ '[[:cntrl:]]'
         ) then
        return false;
      end if;
    end if;

    if checked_normalized_payload ? 'category_id' then
      category_id := checked_normalized_payload ->> 'category_id';
      if category_id is null or category_id !~ '^[0-9]{1,3}$' then
        return false;
      end if;
    end if;

    if checked_normalized_payload ? 'subscriber_count' then
      subscriber_count := checked_normalized_payload ->> 'subscriber_count';
      if subscriber_count is null or subscriber_count !~ '^[0-9]{1,15}$' then
        return false;
      end if;
    end if;

    if checked_normalized_payload ? 'channel_id' then
      channel_id := checked_normalized_payload ->> 'channel_id';
      if channel_id is null or channel_id !~ '^[A-Za-z0-9_-]{3,128}$' then
        return false;
      end if;
    end if;

    -- A projection carrying none of the three label fields describes nothing,
    -- and an observation that describes nothing is not evidence. `channel_id`
    -- alone does not count: it identifies without saying anything.
    return checked_normalized_payload ?| array['topics', 'tags', 'category_id'];
  end if;

  if not semantic_private.is_private_lane_source(checked_source_code) then
    return true;
  end if;
  if checked_source_item_hmac is null
     or checked_source_item_hmac !~ '^[0-9a-f]{64}$'
     or checked_record_fingerprint is null
     or checked_record_fingerprint !~ '^[0-9a-f]{64}$'
     or (
       checked_content_lineage_hmac is not null
       and checked_content_lineage_hmac !~ '^[0-9a-f]{64}$'
     )
     or checked_session_hmac is not null
     or checked_raw_blob_ref is not null
     or checked_field_quality is null
     or checked_field_quality < 0.0
     or checked_field_quality > 1.0
     or checked_allow_external_resolution is distinct from false
     or checked_normalized_payload is null
     or jsonb_typeof(checked_normalized_payload) <> 'object'
     or octet_length(checked_normalized_payload::text) > 1024 then
    return false;
  end if;
  if not (
    (
      checked_lifecycle_state = 'active'
      and checked_exclusion_code is null
      and checked_excluded_at is null
    ) or (
      checked_lifecycle_state in ('excluded', 'deleted')
      and checked_exclusion_code in (
        'policy_excluded', 'user_deleted', 'retention_expired',
        'superseded', 'legacy_sanitized'
      )
      and checked_excluded_at is not null
    )
  ) then
    return false;
  end if;

  if semantic_private.is_private_calendar_source(checked_source_code) then
    classification_state := checked_normalized_payload ->> 'classification_state';
    artifact_type := checked_normalized_payload ->> 'artifact_type';
    if checked_data_type <> 'calendar_event'
       or checked_observation_kind <> 'sanitized_classification'
       or checked_action_type not in ('scheduled', 'booked')
       or checked_payload_schema_version <> 'calendar-v03'
       or checked_privacy_class <> 'private_calendar_sanitized'
       or checked_action_weight <> 0.0
       or checked_normalized_payload ->> 'schema_version' <> 'calendar-v03'
       or checked_normalized_payload ->> 'record_kind'
         <> 'calendar_classification'
       or classification_state not in ('candidate', 'excluded', 'review') then
      return false;
    end if;
    if classification_state = 'candidate' then
      return coalesce(
        checked_occurred_at is not null
        and checked_content_lineage_hmac is not null
        and artifact_type in (
          'travel_itinerary', 'commercial_reservation', 'public_ticket'
        )
        and checked_normalized_payload = jsonb_build_object(
          'schema_version', 'calendar-v03',
          'record_kind', 'calendar_classification',
          'classification_state', 'candidate',
          'artifact_type', artifact_type
        ), false
      );
    end if;
    return coalesce(
      checked_normalized_payload = jsonb_build_object(
        'schema_version', 'calendar-v03',
        'record_kind', 'calendar_classification',
        'classification_state', classification_state
      ), false
    );
  end if;

  candidate_id := checked_normalized_payload ->> 'candidate_id';
  controlled_label := checked_normalized_payload ->> 'controlled_label';
  coverage_state := checked_normalized_payload ->> 'coverage_state';
  return coalesce(checked_data_type = 'fitness_habit'
    and checked_observation_kind = 'routine_projection'
    and checked_action_type = 'routine'
    and checked_occurred_at is not null
    and checked_content_lineage_hmac is null
    and checked_payload_schema_version
      = 'written-healthkit-fitness-v1.0.0'
    and checked_privacy_class = 'private_fitness_sanitized'
    and checked_action_weight = 0.85
    and jsonb_typeof(checked_normalized_payload -> 'candidate_id') = 'string'
    and candidate_id ~
      '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and jsonb_typeof(checked_normalized_payload -> 'controlled_label') = 'string'
    and char_length(controlled_label) between 1 and 120
    and controlled_label !~ '[[:cntrl:]]'
    and coverage_state in ('workout_typed', 'mixed')
    and checked_normalized_payload = jsonb_build_object(
      'schema_version', 'written-healthkit-fitness-v1.0.0',
      'record_kind', 'fitness_habit',
      'classification_state', 'candidate',
      'candidate_id', candidate_id,
      'controlled_label', controlled_label,
      'coverage_state', coverage_state,
      'purpose_scope', 'fitness_connection',
      'policy_version', 'written-healthkit-fitness-v1.0.0'
    ), false);
end;
$$;

-- ---------------------------------------------------------------------------
-- Assertions.
-- ---------------------------------------------------------------------------
--
-- **The projection is checked by calling it, not by reading it.** `0117` read
-- an empty table, answered false for everything, and passed its own structural
-- assertion — so the rule here is that a predicate must be shown answering
-- *both* ways before it is believed. The two calls below are the whole point of
-- the migration: an unsanitised Outlook payload must be refused, and a
-- correctly sanitised one accepted.

do $$
declare
  raw_payload jsonb := jsonb_build_object(
    'title', 'Dinner with Alex', 'location', '14 Elgin Street'
  );
  sanitized_payload jsonb := jsonb_build_object(
    'schema_version', 'calendar-v03',
    'record_kind', 'calendar_classification',
    'classification_state', 'excluded'
  );
  digest_a text := repeat('a', 64);
  digest_b text := repeat('b', 64);
  literal_holdouts int;
begin
  if not exists (
    select 1 from semantic_private.sources
    where source_code = 'outlook_calendar'
      and independence_group = 'calendar'
      and evidence_channel = 'calendar'
      and online_resolution_policy = 'disabled_private'
      and active
  ) then
    raise exception '0133: outlook_calendar is not registered as a calendar source';
  end if;

  if not exists (
    select 1 from semantic_private.connector_record_source_matrix
    where connector_source_code = 'outlook_calendar'
      and record_source_code = 'outlook_calendar'
  ) then
    raise exception '0133: outlook_calendar cannot deliver its own records';
  end if;

  -- The helpers answer both ways, for every source they are asked about.
  if not (
    semantic_private.is_private_calendar_source('outlook_calendar')
    and semantic_private.is_private_calendar_source('apple_calendar')
    and semantic_private.is_private_calendar_source('google_calendar')
    and not semantic_private.is_private_calendar_source('healthkit')
    and not semantic_private.is_private_calendar_source('apple_music')
    and semantic_private.is_private_lane_source('outlook_calendar')
    and semantic_private.is_private_lane_source('healthkit')
    and not semantic_private.is_private_lane_source('apple_music')
    and not semantic_private.is_private_lane_source('youtube')
  ) then
    raise exception '0133: the private-source helpers do not answer as specified';
  end if;

  -- **An Outlook row carrying an event title must be refused**, which is the
  -- protection that would have been absent had the source been registered
  -- without this migration's second half.
  if semantic_private.private_observation_projection_is_valid_v03(
       'outlook_calendar', 'calendar_event', 'sanitized_classification',
       'scheduled', now(), digest_a, digest_b, null, null,
       'calendar-v03', raw_payload, null, 1.0, 0.0,
       'private_calendar_sanitized', false, 'active', null, null
     ) then
    raise exception '0133: an unsanitized outlook_calendar payload was accepted';
  end if;

  -- And the sanitised shape must be accepted, or the source is registered and
  -- can never store anything — a refusal that would only surface at ingestion.
  if not semantic_private.private_observation_projection_is_valid_v03(
       'outlook_calendar', 'calendar_event', 'sanitized_classification',
       'scheduled', now(), digest_a, digest_b, null, null,
       'calendar-v03', sanitized_payload, null, 1.0, 0.0,
       'private_calendar_sanitized', false, 'active', null, null
     ) then
    raise exception '0133: a sanitized outlook_calendar payload was refused';
  end if;

  -- The existing two must be untouched by the rewrite: same call, same answer.
  if not semantic_private.private_observation_projection_is_valid_v03(
       'apple_calendar', 'calendar_event', 'sanitized_classification',
       'scheduled', now(), digest_a, digest_b, null, null,
       'calendar-v03', sanitized_payload, null, 1.0, 0.0,
       'private_calendar_sanitized', false, 'active', null, null
     ) then
    raise exception '0133: apple_calendar stopped accepting a payload it accepted before';
  end if;

  -- **No literal survives.** A sixth function added later that spells the list
  -- out again is the defect this migration exists to end, so the absence is
  -- asserted rather than assumed. `is_private_calendar_source` itself is the
  -- one place the strings are allowed to appear.
  -- `offset 0` for the reason `0102` records: `pg_get_functiondef` raises on
  -- an aggregate, and without a fence the planner may reach one before the
  -- schema filter has excluded it. Same scan, same hazard, and it would have
  -- failed the same way on the next fresh replay.
  select count(*) into literal_holdouts
  from (
    select p.oid
    from pg_proc as p
    join pg_namespace as n on n.oid = p.pronamespace
    where n.nspname = 'semantic_private'
      and p.prokind = 'f'
      and p.proname not in (
        'is_private_calendar_source', 'is_private_lane_source'
      )
    offset 0
  ) f
  where pg_get_functiondef(f.oid) like '%google_calendar%';
  if literal_holdouts <> 0 then
    raise exception
      '0133: % function(s) in semantic_private still name a calendar by literal',
      literal_holdouts;
  end if;

  raise notice '0133: outlook_calendar registered; calendar list centralised';
end;
$$;

commit;
