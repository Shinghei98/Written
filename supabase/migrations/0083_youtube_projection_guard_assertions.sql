-- 0083 — what the YouTube projection guard actually refuses.
--
-- **`0082` was applied without one case ever being run.** The validator is
-- revoked from every client role and the review connection is
-- `supabase_read_only_user`, so it could be neither executed nor tested from
-- outside. The same blindness that let `0080` ship a statement
-- `guard_observation_immutable` refuses on every invocation.
--
-- These assertions run as the migration, which is the one context that *can*
-- call it — and they stay in the chain, so a later edit to the validator that
-- reopens any of these holes fails the replay rather than being discovered by
-- a title sitting in an append-only column.
--
-- The function is `immutable` and pure, so this writes nothing and reads
-- nothing: it is a test that happens to be a migration.

begin;

-- The cases are a values list and the assertion is one statement over it:
-- plpgsql has no nested functions, and nineteen arguments repeated thirteen
-- times would bury the three fields that actually vary. A new case is one row,
-- and a failure names it.
do $$
declare
  failed text;
begin
  with cases(name, payload, kind, privacy, schema_v, expected) as (values
    -- Accepted: the shape the endpoint is expected to send.
    ('topics, tags and category',
     '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
       "topics":["Music","Pop_music"],"tags":["le sserafim"],"category_id":"10"}'::jsonb,
     'provider_labels','public_catalog','youtube-v03', true),
    ('topics only, with a channel id',
     '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
       "topics":["Lifestyle_(sociology)","Role-playing_video_game"],
       "channel_id":"UCabc-123_XYZ"}'::jsonb,
     'provider_labels','public_catalog','youtube-v03', true),

    -- **The case this guard exists for.** A title arriving as its own key.
    ('a title as an extra key',
     '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
       "topics":["Music"],"title":"Matthaus-Passion, BWV 244"}'::jsonb,
     'provider_labels','public_catalog','youtube-v03', false),

    -- **And the subtler one.** A title smuggled into `topics`, which is why
    -- that field is matched against a pattern containing no space.
    ('a title smuggled into topics',
     '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
       "topics":["LE SSERAFIM Stage Mix 4K"]}'::jsonb,
     'provider_labels','public_catalog','youtube-v03', false),
    ('a channel name smuggled into topics',
     '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
       "topics":["Raphael Pichon"]}'::jsonb,
     'provider_labels','public_catalog','youtube-v03', false),

    -- An identifier says nothing on its own; an observation that describes
    -- nothing is not evidence.
    ('channel id but no label at all',
     '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
       "channel_id":"UCabc123"}'::jsonb,
     'provider_labels','public_catalog','youtube-v03', false),

    -- Bounds.
    ('a tag longer than sixty characters',
     ('{"schema_version":"youtube-v03","record_kind":"youtube_labels","tags":["'
      || repeat('a', 61) || '"]}')::jsonb,
     'provider_labels','public_catalog','youtube-v03', false),
    ('a tag carrying a control character',
     '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
       "tags":["kpop\nstage mix"]}'::jsonb,
     'provider_labels','public_catalog','youtube-v03', false),
    ('a non-numeric category id',
     '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
       "topics":["Music"],"category_id":"Music"}'::jsonb,
     'provider_labels','public_catalog','youtube-v03', false),
    ('a channel id with a slash in it',
     '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
       "topics":["Music"],"channel_id":"UC/../etc"}'::jsonb,
     'provider_labels','public_catalog','youtube-v03', false),

    -- Vocabulary.
    ('music''s observation_kind on a YouTube row',
     '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
       "topics":["Music"]}'::jsonb,
     'catalog_item','public_catalog','youtube-v03', false),
    ('a private privacy_class',
     '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
       "topics":["Music"]}'::jsonb,
     'provider_labels','private_text','youtube-v03', false),
    ('music''s schema version',
     '{"schema_version":"music-v03","record_kind":"youtube_labels",
       "topics":["Music"]}'::jsonb,
     'provider_labels','public_catalog','music-v03', false)
  )
  select string_agg(name, '; ') into failed
  from cases
  where semantic_private.private_observation_projection_is_valid_v03(
          'youtube', 'liked_video', kind, 'liked', now(),
          repeat('a', 64), repeat('b', 64), null, null, schema_v, payload,
          null, 1.0, 0.9, privacy, false, 'active', null, null
        ) is distinct from expected;

  if failed is not null then
    raise exception 'YouTube projection guard behaved unexpectedly for: %', failed;
  end if;
end
$$;

-- **The other half: nothing else changed.** `0082` rewrote a function four
-- sources depend on, and a regression there would be silent — Calendar rows
-- would simply stop being accepted, or worse, start being accepted in a shape
-- the classifier never emits.
do $$
declare
  calendar_ok boolean;
  calendar_bad boolean;
  music_ok boolean;
begin
  calendar_ok := semantic_private.private_observation_projection_is_valid_v03(
    'apple_calendar', 'calendar_event', 'sanitized_classification', 'booked',
    now(), repeat('a', 64), repeat('b', 64), repeat('c', 64), null,
    'calendar-v03',
    '{"schema_version":"calendar-v03","record_kind":"calendar_classification",
      "classification_state":"candidate","artifact_type":"public_ticket"}'::jsonb,
    null, 1.0, 0.0, 'private_calendar_sanitized', false, 'active', null, null);
  if not calendar_ok then
    raise exception 'a valid Calendar candidate is no longer accepted';
  end if;

  -- A Calendar payload carrying an event title must still be refused; that is
  -- the closed shape §7 asks for and it predates this migration.
  calendar_bad := semantic_private.private_observation_projection_is_valid_v03(
    'apple_calendar', 'calendar_event', 'sanitized_classification', 'booked',
    now(), repeat('a', 64), repeat('b', 64), repeat('c', 64), null,
    'calendar-v03',
    '{"schema_version":"calendar-v03","record_kind":"calendar_classification",
      "classification_state":"candidate","artifact_type":"public_ticket",
      "title":"Dinner with Anna"}'::jsonb,
    null, 1.0, 0.0, 'private_calendar_sanitized', false, 'active', null, null);
  if calendar_bad then
    raise exception 'a Calendar projection carrying a title is now accepted';
  end if;

  -- Apple Music still falls through the escape hatch untouched: its projection
  -- is a transcription by design and is not governed here.
  music_ok := semantic_private.private_observation_projection_is_valid_v03(
    'apple_music', 'library_song', 'catalog_item', 'library_song', now(),
    repeat('a', 64), repeat('b', 64), null, null, 'music-v03',
    '{"schema_version":"music-v03","record_kind":"music_item","title":"Blank Space"}'::jsonb,
    null, 1.0, 0.48, 'public_catalog', false, 'active', null, null);
  if not music_ok then
    raise exception 'Apple Music projections are no longer accepted';
  end if;
end
$$;

commit;
