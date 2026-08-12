-- 0082 — a closed shape for the YouTube projection, enforced by the server.
--
-- **The validator has an escape hatch and YouTube falls through it.** Its first
-- statement is
--
--     if checked_source_code not in
--        ('apple_calendar', 'google_calendar', 'healthkit')
--     then return true; end if;
--
-- so any YouTube projection would be accepted, including one carrying video
-- titles and channel names. That is not merely untidy: `guard_observation_immutable`
-- freezes `normalized_payload`, so a title landing there could **never** be
-- redacted, and III.E.4 gives thirty days. `0081` records the rule and this is
-- what makes it true — a rule stated in a comment and enforced in a JavaScript
-- `Set` is a convention, which is this codebase's standing defect written in
-- another language.
--
-- **What the shape permits, and why each is defensible.** Provider-assigned
-- classification and identifiers only:
--
--   `topics`       `topicDetails.topicCategories`, reduced by the distiller to
--                  the last path component of a Wikipedia URL. **Matched against
--                  a pattern with no space in it**, which is the anti-smuggling
--                  property that matters: `Music_of_Asia` passes and any real
--                  title fails, so the field cannot be repurposed to carry one.
--   `tags`         `snippet.tags`, the uploader's own labels — the only route to
--                  `uploader_tag`, which `0078` records a determination for.
--                  Bounded at twelve items of sixty characters, matching the cap
--                  `YouTubeDistiller` already applies.
--   `category_id`  a numeric id.
--   `channel_id`   an identifier, not a name. `ontology.youtube_channels` is
--                  keyed on it, so the schema already treats it as persistable,
--                  and the 30-day clause enumerates titles, creator names,
--                  descriptions and comment text — an opaque id is none of them.
--
-- Everything else is refused by subtraction: the payload minus the six allowed
-- keys must be empty, so a new field cannot arrive without a migration.
--
-- **One question this does not settle, and it should be settled before capture
-- is switched on.** Whether `topics` and `tags` are themselves subject to the
-- 30-day rule is genuinely grey — they are neither statistics nor any of the
-- four enumerated kinds, but they are transcriptions of API Data rather than
-- derived output. If the answer is that they expire, then an append-only
-- projection is the wrong home for them and resolution must move to ingestion
-- where the Calendar classifier already lives, storing the resolved concept
-- rather than the provider's word for it. This guard is correct either way; it
-- bounds what may be stored, not how long.

begin;

-- **Identical signature, so this replaces rather than overloads.** Nineteen
-- parameters reproduced exactly from the deployed definition: `0064` was written
-- against an eleven-argument body after a twelfth had been added, and
-- `create or replace` cheerfully created a second function beside the first.
create or replace function semantic_private.private_observation_projection_is_valid_v03(
  checked_source_code text,
  checked_data_type text,
  checked_observation_kind text,
  checked_action_type text,
  checked_occurred_at timestamp with time zone,
  checked_source_item_hmac text,
  checked_record_fingerprint text,
  checked_content_lineage_hmac text,
  checked_session_hmac text,
  checked_payload_schema_version text,
  checked_normalized_payload jsonb,
  checked_raw_blob_ref text,
  checked_field_quality double precision,
  checked_action_weight double precision,
  checked_privacy_class text,
  checked_allow_external_resolution boolean,
  checked_lifecycle_state text,
  checked_exclusion_code text,
  checked_excluded_at timestamp with time zone
)
returns boolean
language plpgsql
immutable
set search_path = ''
as $function$
declare
  classification_state text;
  artifact_type text;
  candidate_id text;
  controlled_label text;
  coverage_state text;
  category_id text;
  channel_id text;
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
        - 'topics' - 'tags' - 'category_id' - 'channel_id') <> '{}'::jsonb then
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

  if checked_source_code not in (
    'apple_calendar', 'google_calendar', 'healthkit'
  ) then
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

  if checked_source_code in ('apple_calendar', 'google_calendar') then
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
$function$;

-- **Exactly one function of this name, asserted rather than assumed.** `0064`
-- overloaded this validator instead of replacing it and nothing failed at the
-- time; `pg_proc` answering two rows was the only evidence.
do $$
declare
  overloads integer;
begin
  select count(*) into overloads
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'semantic_private'
    and p.proname = 'private_observation_projection_is_valid_v03';
  if overloads <> 1 then
    raise exception 'projection validator is overloaded: % definitions', overloads;
  end if;
end
$$;

commit;
