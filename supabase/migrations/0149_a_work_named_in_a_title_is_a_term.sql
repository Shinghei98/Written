-- 0149 — a work named in a title is a term, and the title still never lands.
--
-- **The evidence exists and nothing could see it.** One liked video on the
-- account this was measured against — `名戦3選 - 黒の剣士キリトと閃光のアスナの
-- 軌跡 | ソードアート・オンライン | Netflix Japan` — is the only YouTube attestation
-- of Sword Art Online anywhere in 2,563 rows. Every field the projection keeps
-- says nothing about it: the channel is `Netflix Japan`, the topics are
-- containers (`Entertainment`, `Film`), the uploader tags are empty. The work
-- is named in the one field that may never be stored.
--
-- The owner's determination of 2026-08-13 settles the pattern and this applies
-- it: the title is **read at ingestion, a term derived, the sentence
-- discarded**. III.E.4 requires video titles deleted or refreshed within thirty
-- days, and nothing here stores one — what lands is `work:sword_art_online`, a
-- concept key that has been in our vocabulary since the music tooling minted it,
-- and which is no more YouTube's than `creator:le_sserafim` is Apple Music's.
--
-- ## Why this is recognition, not inference
--
-- III.E.4.h forbids estimating the category or type of a video. This estimates
-- nothing: it matches a work's own name, whole, against a closed list we
-- authored. It is the line already drawn for `snippet.tags` — recognising
-- `physics` is translation, matching `phys` inside a string is a guess wearing
-- the same clothes — and the catalogue enforces it by refusing bare `bleach`,
-- `fate`, `persona` and `sao`, which are words before they are works.
--
-- ## Three things this needed and did not need
--
-- **No new `youtube_semantic_kind`.** `written_title_tag` has been permitted
-- since `0045` and granted by `0135`; a work recognised in a title is a term we
-- derived from a title, which is exactly what that kind names.
--
-- **No new resolution path.** The catalogue emits a concept *key*, and this
-- migration adds each key as an `alternate` label on its own concept, so the
-- existing exact-alias resolver matches it as `curated_alias` at 1.000.
-- `normalize_text` folds `work:sword_art_online` to `work sword art online`,
-- which no real title can collide with. Match labels are `alternate`, never
-- `preferred`, because the prose label is what a person reads on a card.
--
-- **A pattern, not a promise.** `title_works` is bounded to
-- `^work:[a-z0-9_]{1,80}$`, so a title cannot match it. That makes "no prose in
-- this column" structural rather than a claim about the Lambda — no rewrite of
-- the client, and no other holder of the ingestion credential, can put a
-- sentence there. Four items, because a video naming five works names none.
--
-- ## A new ontology version, because a published one is immutable
--
-- The first draft of this migration wrote the aliases straight onto the
-- published version and was refused outright — *"published or retired ontology
-- versions are immutable"*. That guard is the reason `0145` and `0146` copy
-- everything forward, and it is right: an alias added under a version that runs
-- have already been scored against would change what those runs meant after the
-- fact. So `0.15.0` is minted from `0.14.0`, the aliases land there, and the
-- publish is the last thing that happens.
--
-- ## The function is patched, not retyped
--
-- `0102` converted a reader to add a guard by pasting its body and lost the
-- `order by` at the bottom of it. This body is `0146`'s, textually, with three
-- edits applied: the subtraction, the shape rule, and the label-presence test.
-- The label-presence test is the one that is easy to miss — `0146` records that
-- both the JavaScript guard and this one needed the same line and neither side
-- can see the other. A `title_works`-only row is exactly the SAO row.

begin;

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
        - 'subscriber_count' - 'title_hashtags' - 'title_works') <> '{}'::jsonb then
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

    -- **Hashtags out of a video title, bounded exactly as tags are.** They are
    -- the same kind of object — a token the uploader typed — and the bound is
    -- what makes them safe to keep in a store that cannot be rewritten: a
    -- hashtag ends where its word ends, so nothing here can be a sentence.
    -- Twelve of sixty, no control characters, and no whitespace at all, which
    -- is the one rule tags do not have and this needs: a tag may legitimately
    -- be `young sheldon`, while a *hashtag* containing a space would mean the
    -- extractor had taken more than the token.
    if checked_normalized_payload ? 'title_hashtags' then
      if jsonb_typeof(checked_normalized_payload -> 'title_hashtags') <> 'array'
         or jsonb_array_length(checked_normalized_payload -> 'title_hashtags') > 12
         or exists (
           select 1
           from jsonb_array_elements(checked_normalized_payload -> 'title_hashtags') as h
           where jsonb_typeof(h) <> 'string'
              or char_length(h #>> '{}') not between 2 and 60
              or h #>> '{}' ~ '[[:cntrl:][:space:]]'
              or h #>> '{}' ~ '#'
         ) then
        return false;
      end if;
    end if;

    -- **A work named in a title, and the pattern is the whole guard.** What
    -- lands here is a concept key we already hold — `work:sword_art_online` —
    -- never the sentence it was recognised in. The regex is what makes that
    -- structural rather than a promise about the client: a title cannot match
    -- `^work:[a-z0-9_]{1,80}$`, so no rewrite of the Lambda, and no other
    -- caller holding the ingestion credential, can put prose in this column.
    --
    -- Four, because a video naming five works is naming none of them, and the
    -- ingestion catalogue caps at the same number for the same reason.
    if checked_normalized_payload ? 'title_works' then
      if jsonb_typeof(checked_normalized_payload -> 'title_works') <> 'array'
         or jsonb_array_length(checked_normalized_payload -> 'title_works') > 4
         or exists (
           select 1
           from jsonb_array_elements(checked_normalized_payload -> 'title_works') as w
           where jsonb_typeof(w) <> 'string'
              or w #>> '{}' !~ '^work:[a-z0-9_]{1,80}$'
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
    -- **A hashtag is a label, and this is the SQL twin of the same rule in
    -- `youtubeLabels`.** Both encode "an id identifies without describing" —
    -- `channel_id` and `subscriber_count` are absent from this list on purpose
    -- — and both needed the same line adding. The JavaScript one was caught by
    -- a unit test asserting a hashtag-only row is still an observation; this
    -- one was caught by this migration's own probe, which refused a payload
    -- carrying nothing but hashtags. Two guards, one rule, and it had to be
    -- said twice because neither side can see the other.
    return checked_normalized_payload
             ?| array['topics', 'tags', 'category_id', 'title_hashtags', 'title_works'];
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

-- **Copied forward wholesale, because a published version cannot be edited.**
-- The same five inserts `0145` and `0146` use: revisions, labels, edges and
-- motif rules move to the new version unchanged, and only the aliases below are
-- new. `on conflict do nothing` throughout, so a re-run is inert.
insert into ontology.versions (id, version, parent_version_id, status, description, published_at)
select gen_random_uuid(), '0.15.0', v.id, 'draft',
       'A work named in a video title becomes a term.', null
from ontology.versions v where v.version = '0.14.0'
on conflict (version) do nothing;

insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
select new_v.id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
from ontology.concept_revisions r
join ontology.versions old_v on old_v.id = r.ontology_version_id and old_v.version = '0.14.0'
cross join (select id from ontology.versions where version = '0.15.0') new_v
on conflict do nothing;

insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
select new_v.id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
from ontology.concept_labels l
join ontology.versions old_v on old_v.id = l.ontology_version_id and old_v.version = '0.14.0'
cross join (select id from ontology.versions where version = '0.15.0') new_v
on conflict do nothing;

insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
select new_v.id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
from ontology.concept_edges e
join ontology.versions old_v on old_v.id = e.ontology_version_id and old_v.version = '0.14.0'
cross join (select id from ontology.versions where version = '0.15.0') new_v
on conflict do nothing;

insert into ontology.motif_rules (
  id, ontology_version_id, rule_key, evidence_target_concept_id, output_concept_id,
  evidence_predicate_key, output_predicate_key, rule_kind,
  minimum_independence_groups, minimum_strength, configuration, status)
select gen_random_uuid(), new_v.id, m.rule_key, m.evidence_target_concept_id,
       m.output_concept_id, m.evidence_predicate_key, m.output_predicate_key,
       m.rule_kind, m.minimum_independence_groups, m.minimum_strength,
       m.configuration, m.status
from ontology.motif_rules m
join ontology.versions old_v on old_v.id = m.ontology_version_id and old_v.version = '0.14.0'
cross join (select id from ontology.versions where version = '0.15.0') new_v
on conflict do nothing;

-- **Each catalogue work carries its own key as an alias.** This is what lets
-- the ingestion Lambda emit a key and the resolver resolve it with no new code
-- path: `work:sword_art_online` normalizes to `work sword art online`, which
-- matches nothing a person would ever write and everything the catalogue emits.
--
-- Written against `0.15.0` while it is still a draft — a published version is
-- immutable, which is what refused the first attempt — and `on conflict do
-- nothing`, so re-running is inert. `locale` is `und`: a concept key is in no
-- language, which is what that code means and what 15,837 alternates use.
--
-- A key whose concept does not exist inserts no row — the
-- join sees to that — which is the same silent-drop the ingestion catalogue
-- warns about, and the assertion below is what makes it loud.
insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status, external_ref)
select v.id, c.id, k.concept_key,
       replace(replace(k.concept_key, ':', ' '), '_', ' '),
       'und', 'alternate', 'curated', 1.0, 'active', '{}'::jsonb
from (values
  ('work:sword_art_online'),
  ('work:sword_art_online_ii'),
  ('work:sword_art_online_alicization'),
  ('work:bleach_thousand_year_blood_war'),
  ('work:fate_zero'),
  ('work:persona_5_dancing_in_starlight')
) as k(concept_key)
join ontology.concepts c on c.concept_key = k.concept_key
cross join (select id from ontology.versions where version = '0.15.0') v
on conflict do nothing;

update ontology.versions set status = 'retired'
 where version = '0.14.0' and status = 'published';

update ontology.versions set status = 'published', published_at = now()
 where version = '0.15.0';

-- **A behaviour change needs a model version.** A run's identity is
-- `(user, revision, ontology version, resolver, scorer)` and the code version is
-- not in it, so deploying the Lambda re-scores nothing. Retiring 0.6.0 in the
-- same statement, because `finalize_ingestion_run_v031` picks the newest
-- *active* model and leaving two active works only by ordering.
insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:resolver:v0.7.0'),
  'ontology_first_resolver', '0.7.0', 'resolver', null,
  '{"fuzzy": false,'
  ' "exact_terms_only": true,'
  ' "whole_tag_only": true,'
  ' "min_tag_length": 3,'
  ' "youtube_title_works": "a work named outright in a video title becomes a'
  ' term through the bundled catalogue; the key is emitted at ingestion and the'
  ' title is discarded there, so no title reaches normalized_payload. Bare'
  ' words that are also works (bleach, fate, persona, sao) are refused, and the'
  ' most specific alias wins so one video is not counted twice."}'::jsonb,
  'active'
) on conflict (id) do nothing;

update ontology.model_versions
   set status = 'retired'
 where model_role = 'resolver' and version = '0.6.0' and status = 'active';


do $$
declare
  labelled integer;
  actives integer;
  enqueued integer;
begin
  -- **Prove the predicate both ways, over the exact shape being shipped.**
  -- `0117` asserted a rule over an empty table, answered false for everything
  -- and passed its own check; the guard against that is calling the function
  -- and requiring both answers.
  if not semantic_private.private_observation_projection_is_valid_v03(
       'youtube', 'liked_video', 'provider_labels', 'liked_video', now(),
       'a', 'b', null, null, 'youtube-v03',
       '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
         "title_works":["work:sword_art_online"]}'::jsonb,
       null, 1.0, 0.5, 'public_catalog', false, 'active', null, null) then
    raise exception 'a projection carrying title_works is refused';
  end if;

  -- The property the whole lane rests on: a sentence cannot be filed as a work.
  if semantic_private.private_observation_projection_is_valid_v03(
       'youtube', 'liked_video', 'provider_labels', 'liked_video', now(),
       'a', 'b', null, null, 'youtube-v03',
       '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
         "title_works":["Sword Art Online - best fights"]}'::jsonb,
       null, 1.0, 0.5, 'public_catalog', false, 'active', null, null) then
    raise exception 'prose was accepted into title_works';
  end if;

  -- A key of the wrong family is not a work either.
  if semantic_private.private_observation_projection_is_valid_v03(
       'youtube', 'liked_video', 'provider_labels', 'liked_video', now(),
       'a', 'b', null, null, 'youtube-v03',
       '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
         "title_works":["creator:netflix_japan"]}'::jsonb,
       null, 1.0, 0.5, 'public_catalog', false, 'active', null, null) then
    raise exception 'a non-work key was accepted into title_works';
  end if;

  -- **The label-presence test, which is the line that is easy to miss.** The
  -- SAO row carries no tags, no real topics and no category; if `title_works`
  -- did not count as a label, the single row this migration exists for would be
  -- refused as describing nothing.
  if not semantic_private.private_observation_projection_is_valid_v03(
       'youtube', 'liked_video', 'provider_labels', 'liked_video', now(),
       'a', 'b', null, null, 'youtube-v03',
       '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
         "channel_id":"UCnetflixjp","title_works":["work:sword_art_online"]}'::jsonb,
       null, 1.0, 0.5, 'public_catalog', false, 'active', null, null) then
    raise exception 'a title_works-only row was refused as describing nothing';
  end if;

  -- And `0146`'s property is untouched: the title itself is still refused.
  if semantic_private.private_observation_projection_is_valid_v03(
       'youtube', 'liked_video', 'provider_labels', 'liked_video', now(),
       'a', 'b', null, null, 'youtube-v03',
       '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
         "title":"Sheldon ran a red light"}'::jsonb,
       null, 1.0, 0.5, 'public_catalog', false, 'active', null, null) then
    raise exception 'a title was accepted after the rewrite';
  end if;

  -- **The alias exists, or the key resolves to nothing and nobody notices.**
  -- This is the silent failure the ingestion catalogue documents from the other
  -- side: a key with no concept drops without an error.
  select count(*) into labelled
  from ontology.concept_labels l
  join ontology.concepts c on c.id = l.concept_id
  join ontology.versions v on v.id = l.ontology_version_id and v.status = 'published'
  where l.label_type = 'alternate'
    and c.concept_key in ('work:sword_art_online', 'work:sword_art_online_ii',
      'work:sword_art_online_alicization', 'work:bleach_thousand_year_blood_war',
      'work:fate_zero', 'work:persona_5_dancing_in_starlight')
    and l.normalized_label = replace(replace(c.concept_key, ':', ' '), '_', ' ');
  if labelled <> 6 then
    raise exception 'expected 6 work-key aliases, found %', labelled;
  end if;

  select count(*) into actives
  from ontology.model_versions where model_role = 'resolver' and status = 'active';
  if actives <> 1 then
    raise exception 'expected exactly one active resolver, found %', actives;
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           'resolver 0.7.0 and ontology 0.15.0: a work named in a title is a term'
         ) into enqueued;
  raise notice '0149: enqueued % recompute job(s)', enqueued;
end;
$$;

commit;
