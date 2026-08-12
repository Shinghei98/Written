-- 0084 — the projection may carry a subscriber count.
--
-- **The guard refusing this is the guard working.** `0082` closes the YouTube
-- projection by subtraction, so a field it does not name makes the payload
-- non-empty and the projection invalid — "a new field cannot arrive without a
-- migration" was the stated property and this is the first time it has been
-- paid.
--
-- `YouTubeDistiller` now asks `channels.list` for `statistics` alongside
-- `topicDetails` — the same call, the same quota unit, since YouTube charges per
-- call rather than per part. Without this, `subscriber_count` reaches
-- `distilled_records` and can never reach an observation.
--
-- **It is the one field here that is not on the thirty-day clock.** III.E.4
-- permits storing Analytics data, Reporting data and *statistics* beyond 30
-- calendar days, where titles and channel names must be refreshed or deleted.
-- A subscriber count is a statistic by that clause's own example.
--
-- **And it is deliberately a number, not a judgement.** Comparing it against a
-- threshold — "only channels above 100,000 subscribers become their own term" —
-- is reading a figure YouTube publishes. Concluding from it that a channel *is*
-- an official account or a repost account is `channel_role`, which is "the type
-- of a video or channel" in III.E.4.h's own words and stays behind
-- `allow_role_resolution`. The number may be stored; the label may not be made.
--
-- The body below is `0082`'s, extracted from that file verbatim by
-- `tools/`-side scripting rather than retyped, with exactly two edits: the key
-- added to the subtraction, and its own pattern check. Nineteen parameters
-- unchanged, so this replaces rather than overloads — `0064`'s lesson.

begin;

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
do $$
declare
  overloads integer;
  failed text;
begin
  select count(*) into overloads
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'semantic_private'
    and p.proname = 'private_observation_projection_is_valid_v03';
  if overloads <> 1 then
    raise exception 'projection validator is overloaded: % definitions', overloads;
  end if;

  with cases(name, payload, expected) as (values
    ('a subscriber count alongside topics',
     '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
       "topics":["Music"],"subscriber_count":"1230000"}'::jsonb, true),
    ('a subscriber count with a channel id and no label',
     '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
       "channel_id":"UCabc123","subscriber_count":"1230000"}'::jsonb, false),
    ('a non-numeric subscriber count',
     '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
       "topics":["Music"],"subscriber_count":"1.2M"}'::jsonb, false),
    ('a subscriber count with a comma',
     '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
       "topics":["Music"],"subscriber_count":"1,230,000"}'::jsonb, false),
    ('still refuses a title as an extra key',
     '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
       "topics":["Music"],"subscriber_count":"100","title":"BWV 244"}'::jsonb, false),
    ('still refuses a title smuggled into topics',
     '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
       "topics":["LE SSERAFIM Stage Mix 4K"],"subscriber_count":"100"}'::jsonb, false)
  )
  select string_agg(name, '; ') into failed
  from cases
  where semantic_private.private_observation_projection_is_valid_v03(
          'youtube', 'subscription', 'provider_labels', 'subscription', now(),
          repeat('a', 64), repeat('b', 64), null, null, 'youtube-v03', payload,
          null, 1.0, 0.55, 'public_catalog', false, 'active', null, null
        ) is distinct from expected;
  if failed is not null then
    raise exception 'subscriber_count guard behaved unexpectedly for: %', failed;
  end if;
end
$$;

commit;
