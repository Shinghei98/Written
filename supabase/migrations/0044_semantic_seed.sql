-- The versioned ontology seed.
--
-- Adapted from the v0.3.1 package's `003_seed.sql`. The namespace rule and the
-- reason for it are in `0042_semantic_schema.sql`: the reference chain uses
-- `private` for its own objects and this app already owns that schema, so every
-- qualified reference here is `semantic_private`.
--
-- **Only schema references were translated.** Unlike 001 and 002, these files
-- use the word "private" in prose, in exception messages, and as a
-- `sensitivity` check-constraint *value*. Those are left exactly as written; a
-- blanket replace would have changed what the constraint accepts.
--
-- Ships no product behaviour. Nothing in Swift reads any of this.
--
-- Adapted against package v0.3.1, app commit b3e19ae, migration head 0043.

begin;

insert into ontology.relation_types (
  predicate_key, relation_class, inverse_predicate_key, is_symmetric,
  transitive_for_inference, max_inference_hops, assertion_safe, description
) values
  ('broader', 'hierarchical', 'narrower', false, false, 1, true,
   'Direct broader concept; polyhierarchy is allowed.'),
  ('narrower', 'hierarchical', 'broader', false, false, 1, true,
   'Direct narrower concept.'),
  ('related', 'associative', 'related', true, false, 0, false,
   'Association only; never traverse transitively for inference.'),
  ('about', 'descriptive', null, false, false, 1, true,
   'A concept or affinity is about another concept.'),
  ('associated_with_place', 'descriptive', null, false, false, 1, true,
   'Descriptive candidate relation only; never direct motif evidence.'),
  ('supports_cultural_affinity_candidate', 'descriptive', null, false, false, 1, true,
   'Curated, directional support for a reviewable cultural-affinity candidate.'),
  ('cuisine_of', 'descriptive', null, false, false, 1, true,
   'Cuisine-place relation.'),
  ('in_language', 'descriptive', null, false, false, 1, true,
   'Content language; never the user native language.'),
  ('created_by', 'descriptive', null, false, false, 1, true,
   'Work-creator relation.'),
  ('performed_by', 'descriptive', null, false, false, 1, true,
   'Performance-performer relation.'),
  ('listened_to', 'observed_action', null, false, false, 0, false,
   'Observed listening action.'),
  ('watched', 'observed_action', null, false, false, 0, false,
   'Observed watching action.'),
  ('scheduled', 'observed_action', null, false, false, 0, false,
   'Scheduled event; does not establish attendance.'),
  ('completed_activity', 'observed_action', null, false, false, 0, false,
   'Completed activity from a structured fitness source.'),
  ('affinity_to', 'user_claim', null, false, false, 0, true,
   'Defeasible or explicit user affinity.'),
  ('routine', 'user_claim', null, false, false, 0, true,
   'Reviewable behavioral routine.'),
  ('self_identifies_as', 'user_claim', null, false, false, 0, false,
   'Explicit-only identity path, never behaviorally inferred.')
on conflict (predicate_key) do nothing;

insert into semantic_private.sources (
  source_code, provider, evidence_channel, independence_group,
  online_resolution_policy, default_reliability, action_weights
) values
  ('apple_music', 'apple', 'music', 'music', 'catalog_ids_only', 0.90,
   '{"library_song":0.48,"library_album":0.55,"library_artist":0.45,"library_playlist":0.60,"playlist_item":0.70,"rating":0.88,"recently_added":0.55,"recently_played":0.78,"recommendation":0.0}'::jsonb),
  ('music_library', 'apple_local', 'music', 'music', 'public_metadata_only', 0.75,
   '{"library_song":0.48}'::jsonb),
  ('spotify', 'spotify', 'music', 'music', 'catalog_ids_only', 0.90,
   '{"saved":0.60,"playlist_item":0.70,"recently_played":0.78}'::jsonb),
  ('youtube', 'google', 'video', 'video', 'public_metadata_only', 0.80,
   '{"subscription":0.55,"watched":0.72,"liked":0.90,"liked_video":0.90,"shared":0.92,"playlist":0.0,"playlist_item":0.0}'::jsonb),
  ('apple_calendar', 'apple', 'calendar', 'calendar', 'disabled_private', 0.65,
   '{"scheduled":0.25,"booked":0.65,"entered_by_user":0.55,"cancelled":0.0}'::jsonb),
  ('google_calendar', 'google', 'calendar', 'calendar', 'disabled_private', 0.65,
   '{"scheduled":0.25,"booked":0.65,"entered_by_user":0.55,"cancelled":0.0}'::jsonb),
  ('apple_podcasts', 'apple', 'podcast', 'podcast', 'catalog_ids_only', 0.80,
   '{"followed":0.70,"played":0.75,"saved":0.82}'::jsonb),
  ('podcast', 'written', 'podcast', 'podcast', 'public_metadata_only', 0.80,
   '{"show":0.50,"episode":0.62,"followed":0.70,"played":0.75,"saved":0.82}'::jsonb),
  ('healthkit', 'apple', 'movement', 'movement', 'not_applicable', 0.90,
   '{"activity_day":0.0,"activity_hour":0.0,"completed_activity":0.0,"accelerometer_sample":0.0}'::jsonb),
  ('user', 'written', 'explicit_profile', 'explicit_profile', 'not_applicable', 1.00,
   '{}'::jsonb),
  ('location', 'written', 'location', 'location', 'not_applicable', 0.00,
   '{}'::jsonb)
on conflict (source_code) do update
set provider = excluded.provider,
    evidence_channel = excluded.evidence_channel,
    independence_group = excluded.independence_group,
    online_resolution_policy = excluded.online_resolution_policy,
    default_reliability = excluded.default_reliability,
    action_weights = excluded.action_weights;

-- Bootstrap HealthKit fail-closed. Migration 005 activates the source only
-- after installing the purpose-limited fitness ingestion, grant, derivation,
-- and surface contracts.
update semantic_private.sources
set active = false
where source_code = 'healthkit';

insert into ontology.versions (id, version, status, description)
values (
  ontology.stable_uuid('written:ontology:v0.1.0'),
  '0.1.0',
  'draft',
  'Provisional hub registry and Italy convergence golden path.'
)
on conflict (version) do nothing;

with seed(concept_key) as (
  values
    ('hub:music'),
    ('hub:film_video'),
    ('hub:ideas_learning'),
    ('hub:sports_movement'),
    ('hub:food_drink'),
    ('hub:arts_live'),
    ('hub:places_cultures'),
    ('hub:games_play'),
    ('hub:nature_outdoors'),
    ('hub:work_study_making'),
    ('hub:social_community'),
    ('hub:animals_pets'),
    ('hub:daily_rhythms'),
    ('place:italy'),
    ('concept:italian_music'),
    ('concept:italian_cinema'),
    ('concept:italian_cuisine'),
    ('affinity:culture:italy'),
    ('identity:italian_ancestry'),
    ('identity:italian_nationality'),
    ('identity:italian_native_language'),
    ('activity:running'),
    ('activity:walking'),
    ('activity:cycling'),
    ('activity:swimming'),
    ('activity:hiking'),
    ('activity:strength_training'),
    ('activity:yoga'),
    ('activity:pilates'),
    ('activity:dance'),
    ('activity:hiit'),
    ('activity:rowing'),
    ('activity:elliptical'),
    ('activity:climbing'),
    ('activity:tennis'),
    ('activity:pickleball'),
    ('activity:basketball'),
    ('activity:soccer'),
    ('activity:skiing'),
    ('activity:snowboarding'),
    ('routine:morning_workouts'),
    ('routine:afternoon_workouts'),
    ('routine:evening_workouts'),
    ('routine:overnight_workouts'),
    ('routine:consistent_sleep_schedule')
)
insert into ontology.concepts (id, concept_key)
select ontology.stable_uuid('written:concept:' || concept_key), concept_key
from seed
on conflict (concept_key) do nothing;

with revision_seed(
  concept_key, preferred_label, concept_kind, sensitivity,
  inference_policy, status, definition
) as (
  values
    ('hub:music', 'Music', 'hub', 'ordinary', 'inferable', 'active', 'Provisional fixed hub.'),
    ('hub:film_video', 'Film, TV & video', 'hub', 'ordinary', 'inferable', 'active', 'Provisional fixed hub.'),
    ('hub:ideas_learning', 'Books, ideas & learning', 'hub', 'ordinary', 'inferable', 'active', 'Podcast is a medium within this area.'),
    ('hub:sports_movement', 'Sports & movement', 'hub', 'ordinary', 'review_required', 'active', 'Purpose-limited fitness evidence, including reviewed HealthKit-derived routines when consent and coverage gates pass.'),
    ('hub:food_drink', 'Food & drink', 'hub', 'ordinary', 'inferable', 'active', 'Reservations are scheduled, not attended.'),
    ('hub:arts_live', 'Arts & live culture', 'hub', 'ordinary', 'inferable', 'active', 'Events and live culture.'),
    ('hub:places_cultures', 'Places, travel & cultures', 'hub', 'ordinary', 'review_required', 'active', 'Cultural affinity only; no ancestry.'),
    ('hub:games_play', 'Games & play', 'hub', 'ordinary', 'inferable', 'draft', 'Not directly observed in the current V1 sources.'),
    ('hub:nature_outdoors', 'Nature & outdoors', 'hub', 'ordinary', 'inferable', 'draft', 'Candidate hub.'),
    ('hub:work_study_making', 'Work, study & making', 'hub', 'private', 'explicit_only', 'draft', 'Confirmation-only in V0.'),
    ('hub:social_community', 'Social life & community', 'hub', 'private', 'review_required', 'draft', 'Private by default.'),
    ('hub:animals_pets', 'Animals & pets', 'hub', 'ordinary', 'review_required', 'draft', 'Pet health and personality remain explicit.'),
    ('hub:daily_rhythms', 'Daily rhythms & routines', 'hub', 'private', 'review_required', 'draft', 'Quantitative behavior, not identity.'),
    ('place:italy', 'Italy', 'place', 'ordinary', 'review_required', 'active', 'Reusable convergence target.'),
    ('concept:italian_music', 'Italian music', 'topic', 'ordinary', 'inferable', 'active', 'Music associated with Italy.'),
    ('concept:italian_cinema', 'Italian cinema', 'topic', 'ordinary', 'inferable', 'active', 'Cinema associated with Italy.'),
    ('concept:italian_cuisine', 'Italian cuisine', 'cuisine', 'ordinary', 'review_required', 'active', 'Cuisine associated with Italy.'),
    ('affinity:culture:italy', 'Italian cultural affinity', 'affinity', 'ordinary', 'review_required', 'active', 'Pending-review wording after independent convergence.'),
    ('identity:italian_ancestry', 'Italian ancestry', 'identity', 'sensitive', 'explicit_only', 'blocked', 'Never infer from consumption.'),
    ('identity:italian_nationality', 'Italian nationality', 'identity', 'sensitive', 'explicit_only', 'blocked', 'Never infer from consumption.'),
    ('identity:italian_native_language', 'Italian native language', 'identity', 'sensitive', 'explicit_only', 'blocked', 'Never infer from consumption.'),
    ('activity:running', 'Running', 'activity', 'ordinary', 'review_required', 'active', 'Typed fitness activity; routine wording requires recurrence and review.'),
    ('activity:walking', 'Walking', 'activity', 'ordinary', 'review_required', 'active', 'Typed fitness activity; routine wording requires recurrence and review.'),
    ('activity:cycling', 'Cycling', 'activity', 'ordinary', 'review_required', 'active', 'Typed fitness activity; routine wording requires recurrence and review.'),
    ('activity:swimming', 'Swimming', 'activity', 'ordinary', 'review_required', 'active', 'Typed fitness activity; routine wording requires recurrence and review.'),
    ('activity:hiking', 'Hiking', 'activity', 'ordinary', 'review_required', 'active', 'Typed fitness activity; routine wording requires recurrence and review.'),
    ('activity:strength_training', 'Strength training', 'activity', 'ordinary', 'review_required', 'active', 'Typed fitness activity; routine wording requires recurrence and review.'),
    ('activity:yoga', 'Yoga', 'activity', 'ordinary', 'review_required', 'active', 'Typed fitness activity; routine wording requires recurrence and review.'),
    ('activity:pilates', 'Pilates', 'activity', 'ordinary', 'review_required', 'active', 'Typed fitness activity; routine wording requires recurrence and review.'),
    ('activity:dance', 'Dance', 'activity', 'ordinary', 'review_required', 'active', 'Typed fitness activity; routine wording requires recurrence and review.'),
    ('activity:hiit', 'HIIT', 'activity', 'ordinary', 'review_required', 'active', 'Typed fitness activity; routine wording requires recurrence and review.'),
    ('activity:rowing', 'Rowing', 'activity', 'ordinary', 'review_required', 'active', 'Typed fitness activity; routine wording requires recurrence and review.'),
    ('activity:elliptical', 'Elliptical training', 'activity', 'ordinary', 'review_required', 'active', 'Typed fitness activity; routine wording requires recurrence and review.'),
    ('activity:climbing', 'Climbing', 'activity', 'ordinary', 'review_required', 'active', 'Typed fitness activity; routine wording requires recurrence and review.'),
    ('activity:tennis', 'Tennis', 'activity', 'ordinary', 'review_required', 'active', 'Typed fitness activity; routine wording requires recurrence and review.'),
    ('activity:pickleball', 'Pickleball', 'activity', 'ordinary', 'review_required', 'active', 'Typed fitness activity; routine wording requires recurrence and review.'),
    ('activity:basketball', 'Basketball', 'activity', 'ordinary', 'review_required', 'active', 'Typed fitness activity; routine wording requires recurrence and review.'),
    ('activity:soccer', 'Soccer', 'activity', 'ordinary', 'review_required', 'active', 'Typed fitness activity; routine wording requires recurrence and review.'),
    ('activity:skiing', 'Skiing', 'activity', 'ordinary', 'review_required', 'active', 'Typed fitness activity; routine wording requires recurrence and review.'),
    ('activity:snowboarding', 'Snowboarding', 'activity', 'ordinary', 'review_required', 'active', 'Typed fitness activity; routine wording requires recurrence and review.'),
    ('routine:morning_workouts', 'Morning workouts', 'activity', 'ordinary', 'review_required', 'active', 'Coarse workout timing routine; requires recurrence and review.'),
    ('routine:afternoon_workouts', 'Afternoon workouts', 'activity', 'ordinary', 'review_required', 'active', 'Coarse workout timing routine; requires recurrence and review.'),
    ('routine:evening_workouts', 'Evening workouts', 'activity', 'ordinary', 'review_required', 'active', 'Coarse workout timing routine; requires recurrence and review.'),
    ('routine:overnight_workouts', 'Overnight workouts', 'activity', 'ordinary', 'review_required', 'active', 'Coarse workout timing routine; requires recurrence and review.'),
    ('routine:consistent_sleep_schedule', 'Consistent sleep schedule', 'activity', 'ordinary', 'review_required', 'active', 'Coarse wellness routine; never sleep quality or diagnosis.')
)
insert into ontology.concept_revisions (
  ontology_version_id, concept_id, preferred_label, concept_kind,
  definition, sensitivity, inference_policy, status
)
select
  ontology.stable_uuid('written:ontology:v0.1.0'),
  concept.id,
  seed.preferred_label,
  seed.concept_kind,
  seed.definition,
  seed.sensitivity,
  seed.inference_policy,
  seed.status
from revision_seed as seed
join ontology.concepts as concept using (concept_key)
where exists (
  select 1 from ontology.versions
  where id = ontology.stable_uuid('written:ontology:v0.1.0')
    and status = 'draft'
)
on conflict (ontology_version_id, concept_id) do nothing;

with label_seed(concept_key, label, locale, label_type, confidence) as (
  values
    ('hub:music', 'music', 'en', 'preferred', 1.0),
    ('hub:film_video', 'movie', 'en', 'alternate', 1.0),
    ('hub:film_video', 'film', 'en', 'alternate', 1.0),
    ('hub:film_video', 'tv', 'en', 'alternate', 1.0),
    ('hub:ideas_learning', 'podcast', 'en', 'source_term', 0.9),
    ('hub:sports_movement', 'workout', 'en', 'alternate', 1.0),
    ('hub:sports_movement', 'exercise', 'en', 'alternate', 1.0),
    ('hub:food_drink', 'restaurant', 'en', 'alternate', 0.8),
    ('place:italy', 'Italy', 'en', 'preferred', 1.0),
    ('place:italy', 'Italian', 'en', 'related_label', 0.75),
    ('place:italy', 'Italia', 'it', 'alternate', 1.0),
    ('concept:italian_music', 'Italian music', 'en', 'preferred', 1.0),
    ('concept:italian_music', 'musica italiana', 'it', 'alternate', 1.0),
    ('concept:italian_cinema', 'Italian cinema', 'en', 'preferred', 1.0),
    ('concept:italian_cinema', 'cinema italiano', 'it', 'alternate', 1.0),
    ('concept:italian_cuisine', 'Italian food', 'en', 'alternate', 0.95),
    ('concept:italian_cuisine', 'Italian cuisine', 'en', 'preferred', 1.0),
    ('concept:italian_cuisine', 'cucina italiana', 'it', 'alternate', 1.0),
    ('activity:running', 'Running', 'en', 'preferred', 1.0),
    ('activity:walking', 'Walking', 'en', 'preferred', 1.0),
    ('activity:cycling', 'Cycling', 'en', 'preferred', 1.0),
    ('activity:swimming', 'Swimming', 'en', 'preferred', 1.0),
    ('activity:hiking', 'Hiking', 'en', 'preferred', 1.0),
    ('activity:strength_training', 'Strength training', 'en', 'preferred', 1.0),
    ('activity:yoga', 'Yoga', 'en', 'preferred', 1.0),
    ('activity:pilates', 'Pilates', 'en', 'preferred', 1.0),
    ('activity:dance', 'Dance', 'en', 'preferred', 1.0),
    ('activity:hiit', 'HIIT', 'en', 'preferred', 1.0),
    ('activity:rowing', 'Rowing', 'en', 'preferred', 1.0),
    ('activity:elliptical', 'Elliptical training', 'en', 'preferred', 1.0),
    ('activity:climbing', 'Climbing', 'en', 'preferred', 1.0),
    ('activity:tennis', 'Tennis', 'en', 'preferred', 1.0),
    ('activity:pickleball', 'Pickleball', 'en', 'preferred', 1.0),
    ('activity:basketball', 'Basketball', 'en', 'preferred', 1.0),
    ('activity:soccer', 'Soccer', 'en', 'preferred', 1.0),
    ('activity:skiing', 'Skiing', 'en', 'preferred', 1.0),
    ('activity:snowboarding', 'Snowboarding', 'en', 'preferred', 1.0),
    ('routine:morning_workouts', 'Morning workouts', 'en', 'preferred', 1.0),
    ('routine:afternoon_workouts', 'Afternoon workouts', 'en', 'preferred', 1.0),
    ('routine:evening_workouts', 'Evening workouts', 'en', 'preferred', 1.0),
    ('routine:overnight_workouts', 'Overnight workouts', 'en', 'preferred', 1.0),
    ('routine:consistent_sleep_schedule', 'Consistent sleep schedule', 'en', 'preferred', 1.0)
)
insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status
)
select
  ontology.stable_uuid('written:ontology:v0.1.0'),
  concept.id,
  seed.label,
  lower(seed.label),
  seed.locale,
  seed.label_type,
  'curated',
  seed.confidence,
  'active'
from label_seed as seed
join ontology.concepts as concept using (concept_key)
where exists (
  select 1 from ontology.versions
  where id = ontology.stable_uuid('written:ontology:v0.1.0')
    and status = 'draft'
)
on conflict (ontology_version_id, concept_id, locale, normalized_label, label_type) do nothing;

with edge_seed(
  subject_key, predicate_key, object_key, confidence, provenance_type, status
) as (
  values
    ('concept:italian_music', 'broader', 'hub:music', 1.0, 'curated', 'active'),
    ('concept:italian_cinema', 'broader', 'hub:film_video', 1.0, 'curated', 'active'),
    ('concept:italian_cuisine', 'broader', 'hub:food_drink', 1.0, 'curated', 'active'),
    ('concept:italian_music', 'associated_with_place', 'place:italy', 1.0, 'curated', 'candidate'),
    ('concept:italian_cinema', 'associated_with_place', 'place:italy', 1.0, 'curated', 'candidate'),
    ('concept:italian_cuisine', 'associated_with_place', 'place:italy', 1.0, 'curated', 'candidate'),
    ('concept:italian_music', 'supports_cultural_affinity_candidate', 'place:italy', 1.0, 'curated', 'active'),
    ('concept:italian_cinema', 'supports_cultural_affinity_candidate', 'place:italy', 1.0, 'curated', 'active'),
    ('concept:italian_cuisine', 'supports_cultural_affinity_candidate', 'place:italy', 1.0, 'curated', 'active'),
    ('affinity:culture:italy', 'about', 'place:italy', 1.0, 'curated', 'active'),
    ('identity:italian_ancestry', 'about', 'place:italy', 1.0, 'curated', 'blocked'),
    ('identity:italian_nationality', 'about', 'place:italy', 1.0, 'curated', 'blocked'),
    ('identity:italian_native_language', 'about', 'place:italy', 1.0, 'curated', 'blocked'),
    ('activity:running', 'broader', 'hub:sports_movement', 1.0, 'curated', 'active'),
    ('activity:walking', 'broader', 'hub:sports_movement', 1.0, 'curated', 'active'),
    ('activity:cycling', 'broader', 'hub:sports_movement', 1.0, 'curated', 'active'),
    ('activity:swimming', 'broader', 'hub:sports_movement', 1.0, 'curated', 'active'),
    ('activity:hiking', 'broader', 'hub:sports_movement', 1.0, 'curated', 'active'),
    ('activity:strength_training', 'broader', 'hub:sports_movement', 1.0, 'curated', 'active'),
    ('activity:yoga', 'broader', 'hub:sports_movement', 1.0, 'curated', 'active'),
    ('activity:pilates', 'broader', 'hub:sports_movement', 1.0, 'curated', 'active'),
    ('activity:dance', 'broader', 'hub:sports_movement', 1.0, 'curated', 'active'),
    ('activity:hiit', 'broader', 'hub:sports_movement', 1.0, 'curated', 'active'),
    ('activity:rowing', 'broader', 'hub:sports_movement', 1.0, 'curated', 'active'),
    ('activity:elliptical', 'broader', 'hub:sports_movement', 1.0, 'curated', 'active'),
    ('activity:climbing', 'broader', 'hub:sports_movement', 1.0, 'curated', 'active'),
    ('activity:tennis', 'broader', 'hub:sports_movement', 1.0, 'curated', 'active'),
    ('activity:pickleball', 'broader', 'hub:sports_movement', 1.0, 'curated', 'active'),
    ('activity:basketball', 'broader', 'hub:sports_movement', 1.0, 'curated', 'active'),
    ('activity:soccer', 'broader', 'hub:sports_movement', 1.0, 'curated', 'active'),
    ('activity:skiing', 'broader', 'hub:sports_movement', 1.0, 'curated', 'active'),
    ('activity:snowboarding', 'broader', 'hub:sports_movement', 1.0, 'curated', 'active'),
    ('routine:morning_workouts', 'broader', 'hub:sports_movement', 1.0, 'curated', 'active'),
    ('routine:afternoon_workouts', 'broader', 'hub:sports_movement', 1.0, 'curated', 'active'),
    ('routine:evening_workouts', 'broader', 'hub:sports_movement', 1.0, 'curated', 'active'),
    ('routine:overnight_workouts', 'broader', 'hub:sports_movement', 1.0, 'curated', 'active'),
    ('routine:consistent_sleep_schedule', 'broader', 'hub:daily_rhythms', 1.0, 'curated', 'active')
)
insert into ontology.concept_edges (
  ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
  confidence, provenance_type, provenance, status
)
select
  ontology.stable_uuid('written:ontology:v0.1.0'),
  subject_concept.id,
  seed.predicate_key,
  object_concept.id,
  seed.confidence,
  seed.provenance_type,
  '{"curation":"seed_v0.1"}'::jsonb,
  seed.status
from edge_seed as seed
join ontology.concepts as subject_concept
  on subject_concept.concept_key = seed.subject_key
join ontology.concepts as object_concept
  on object_concept.concept_key = seed.object_key
where exists (
  select 1 from ontology.versions
  where id = ontology.stable_uuid('written:ontology:v0.1.0')
    and status = 'draft'
)
on conflict (
  ontology_version_id, subject_concept_id, predicate_key,
  object_concept_id, provenance_type
) do nothing;

insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values
  (ontology.stable_uuid('written:model:extractor:v0.1.0'), 'structured_source_extractor', '0.1.0', 'extractor', null,
   '{"private_calendar_online_resolution":false}'::jsonb, 'active'),
  (ontology.stable_uuid('written:model:resolver:v0.1.0'), 'ontology_first_resolver', '0.1.0', 'resolver', null,
   '{"cascade":["provider_id","curated_alias","lexical","embedding_candidate","external_candidate"],"embedding_only_publish":false}'::jsonb, 'active'),
  (ontology.stable_uuid('written:model:scorer:v0.1.0'), 'missing_aware_late_fusion', '0.1.0', 'scorer', null,
   '{"per_lineage_cap":0.75,"source_alpha":0.72,"cross_source_gamma":0.16,"minimum_convergence_groups":2}'::jsonb, 'active'),
  (ontology.stable_uuid('written:model:surfacing:v0.1.0'), 'beta_acceptance_prior', '0.1.0', 'surfacing', null,
   '{"alpha":4.0,"beta":2.0,"removal_semantics":"ambiguous_rejection"}'::jsonb, 'active'),
  (ontology.stable_uuid('written:model:term_miner:v0.1.0'), 'privacy_thresholded_term_miner', '0.1.0', 'term_miner', null,
   '{"minimum_distinct_users":5,"auto_promote":false}'::jsonb, 'active')
on conflict (model_key, version) do nothing;

insert into ontology.embedding_models (
  id, model_key, dimensions, revision, status, metadata
) values (
  ontology.stable_uuid('written:embedding:hashing-ngram-384:v0.1.0'),
  'hashing-ngram-384', 384, '0.1.0', 'active',
  '{"purpose":"offline deterministic candidate generation only","entailment":false}'::jsonb
)
on conflict (model_key) do nothing;

insert into ontology.motif_rules (
  id, ontology_version_id, rule_key,
  evidence_target_concept_id, output_concept_id, rule_kind,
  evidence_predicate_key, output_predicate_key,
  minimum_independence_groups, minimum_strength, configuration, status
)
select
  ontology.stable_uuid('written:motif:cultural-affinity-italy:v0.1.0'),
  ontology.stable_uuid('written:ontology:v0.1.0'),
  'cultural_affinity_convergence:italy',
  place_concept.id,
  affinity_concept.id,
  'shared_target_convergence',
  'supports_cultural_affinity_candidate',
  'affinity_to',
  2,
  0.35,
  '{"state":"pending_user_review","forbidden_outputs":["ancestry","nationality","native_language"]}'::jsonb,
  'active'
from ontology.concepts as place_concept
cross join ontology.concepts as affinity_concept
where place_concept.concept_key = 'place:italy'
  and affinity_concept.concept_key = 'affinity:culture:italy'
  and exists (
    select 1 from ontology.versions
    where id = ontology.stable_uuid('written:ontology:v0.1.0')
      and status = 'draft'
  )
on conflict (ontology_version_id, rule_key) do nothing;

select ontology.publish_version(id)
from ontology.versions
where id = ontology.stable_uuid('written:ontology:v0.1.0')
  and status = 'draft';

commit;
