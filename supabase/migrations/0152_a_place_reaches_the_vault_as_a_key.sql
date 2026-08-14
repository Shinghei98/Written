-- 0152 — a place reaches the vault, and only ever as a key.
--
-- **The itinerary rule was built, never called, and its answer was discarded.**
-- `written_ontology.calendar_semantics` has carried `build_journeys`,
-- `Journey.transit_place_ids` and `TravelCandidate` since it was written — one
-- strong ticket is sufficient, recurrence is counted by journeys rather than
-- legs, and a repeated round trip is `possible_base_for_review` and explicitly
-- *"does not identify a home or hometown"*. The classifier Lambda called none of
-- them, classifying one row at a time, and the projection kept four keys with no
-- destination in them. Every trip reached the vault as "a travel_itinerary
-- happened" and nowhere.
--
-- Measured on the account this was built against, the rule earns its keep
-- immediately. Four flights, two journeys:
--
--     STL -> LAX -> HKG        terminal place:hong_kong,   LAX transit
--     HKG -> LAX -> STL        terminal place:saint_louis, LAX transit
--
-- Los Angeles appears more often than anywhere else and contributes **zero**.
-- Under a naive per-leg count it would have been the strongest place signal on
-- the account, and it is a connection on the Hong Kong route.
--
-- ## What may cross, and what still may not
--
-- `place_key` is our vocabulary — `place:hong_kong` is the same kind of object
-- as `work:sword_art_online` — and the pattern is what makes that structural
-- rather than a promise: `^place:[a-z0-9_]{1,80}$` cannot match a sentence, so
-- no later edit to the classifier can turn this payload back into prose. The
-- title, the location string, the organiser and the email domain are all still
-- discarded in the Lambda and a test asserts it.
--
-- **The exactness of the check is kept.** The candidate branch compares the
-- whole payload against `jsonb_build_object` rather than listing permitted keys,
-- which is stronger than subtraction: an unknown key cannot ride along. So this
-- widens it to *two* exact shapes — the four keys as before, or those four plus
-- a well-formed `place_key` — instead of relaxing the comparison.
--
-- ## Places only; affinities wait
--
-- The twelve places the offline catalogue can resolve are minted here.
-- `affinity:culture:*` is deliberately **not**, though `0146` authored the
-- template for Italy, because two questions in
-- `semantic/docs/CALENDAR_PLACES.md` are open and both bear on it: whether an
-- affinity expires, and how a base differs from one. Hong Kong and St. Louis are
-- this account's bases rather than places it is drawn to, and minting
-- `affinity:culture:hong_kong` for somebody who lives there would be the first
-- step toward an origin claim — which `identity:italian_ancestry` and
-- `identity:italian_nationality`, both `blocked`, exist to refuse.
--
-- Each place also carries its own key as an `alternate` label, exactly as
-- `0149` did for works, so the ordinary exact-alias resolver can match what the
-- projection emits with no new resolution path.

begin;

insert into ontology.versions (id, version, parent_version_id, status, description, published_at)
select gen_random_uuid(), '0.16.0', v.id, 'draft',
       'Places a journey terminates at become terms.', null
from ontology.versions v where v.version = '0.15.0'
on conflict (version) do nothing;

insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
select new_v.id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
from ontology.concept_revisions r
join ontology.versions old_v on old_v.id = r.ontology_version_id and old_v.version = '0.15.0'
cross join (select id from ontology.versions where version = '0.16.0') new_v
on conflict do nothing;

insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
select new_v.id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
from ontology.concept_labels l
join ontology.versions old_v on old_v.id = l.ontology_version_id and old_v.version = '0.15.0'
cross join (select id from ontology.versions where version = '0.16.0') new_v
on conflict do nothing;

insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
select new_v.id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
from ontology.concept_edges e
join ontology.versions old_v on old_v.id = e.ontology_version_id and old_v.version = '0.15.0'
cross join (select id from ontology.versions where version = '0.16.0') new_v
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
join ontology.versions old_v on old_v.id = m.ontology_version_id and old_v.version = '0.15.0'
cross join (select id from ontology.versions where version = '0.16.0') new_v
on conflict do nothing;

-- The twelve the offline catalogue resolves. `review_required` throughout: a
-- place is where somebody was, and the reading of that is a judgement rather
-- than something to infer freely.
create temporary table seed_place (concept_key text primary key, label text not null) on commit drop;
insert into seed_place values
  ('place:hong_kong', 'Hong Kong'),
  ('place:saint_louis', 'St. Louis'),
  ('place:los_angeles', 'Los Angeles'),
  ('place:new_york', 'New York'),
  ('place:san_francisco', 'San Francisco'),
  ('place:chicago', 'Chicago'),
  ('place:seattle', 'Seattle'),
  ('place:london', 'London'),
  ('place:paris', 'Paris'),
  ('place:tokyo', 'Tokyo'),
  ('place:singapore', 'Singapore'),
  ('place:taipei', 'Taipei');

insert into ontology.concepts (id, concept_key)
select gen_random_uuid(), p.concept_key from seed_place p
on conflict (concept_key) do nothing;

insert into ontology.concept_revisions (
  ontology_version_id, concept_id, preferred_label, concept_kind,
  sensitivity, inference_policy, status)
select v.id, c.id, p.label, 'place', 'ordinary', 'review_required', 'active'
from seed_place p
join ontology.concepts c on c.concept_key = p.concept_key
cross join (select id from ontology.versions where version = '0.16.0') v
on conflict do nothing;

-- The prose label a person reads, and the key the resolver matches.
insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status, external_ref)
select v.id, c.id, p.label, lower(p.label), 'en', 'preferred', 'curated', 1.0, 'active', '{}'::jsonb
from seed_place p
join ontology.concepts c on c.concept_key = p.concept_key
cross join (select id from ontology.versions where version = '0.16.0') v
on conflict do nothing;

insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status, external_ref)
select v.id, c.id, p.concept_key,
       replace(replace(p.concept_key, ':', ' '), '_', ' '),
       'und', 'alternate', 'curated', 1.0, 'active', '{}'::jsonb
from seed_place p
join ontology.concepts c on c.concept_key = p.concept_key
cross join (select id from ontology.versions where version = '0.16.0') v
on conflict do nothing;

update ontology.versions set status = 'retired'
 where version = '0.15.0' and status = 'published';

update ontology.versions set status = 'published', published_at = now()
 where version = '0.16.0';

-- The guard, patched from the catalog rather than from a file — `0150` trusted
-- a migration to say what production runs and it did not.
do $migration$
declare
  src text;
  patched text;
  anchor text := $a$        and checked_normalized_payload = jsonb_build_object(
          'schema_version', 'calendar-v03',
          'record_kind', 'calendar_classification',
          'classification_state', 'candidate',
          'artifact_type', artifact_type
        ), false$a$;
  replacement text := $a$        and (
          checked_normalized_payload = jsonb_build_object(
            'schema_version', 'calendar-v03',
            'record_kind', 'calendar_classification',
            'classification_state', 'candidate',
            'artifact_type', artifact_type
          )
          or (
            checked_normalized_payload ->> 'place_key' ~ '^place:[a-z0-9_]{1,80}$'
            and checked_normalized_payload - 'place_key' = jsonb_build_object(
              'schema_version', 'calendar-v03',
              'record_kind', 'calendar_classification',
              'classification_state', 'candidate',
              'artifact_type', artifact_type
            )
          )
        ), false$a$;
begin
  select pg_get_functiondef(p.oid) into src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'semantic_private'
    and p.proname = 'private_observation_projection_is_valid_v03';

  if src is null then
    raise exception 'no projection guard to patch';
  end if;
  if position(anchor in src) = 0 then
    raise exception 'the calendar candidate shape has drifted; refusing to patch';
  end if;

  patched := replace(src, anchor, replacement);
  if patched = src then
    raise exception 'the patch changed nothing';
  end if;
  execute patched;
end;
$migration$;

do $$
declare
  places integer;
  enqueued integer;
begin
  -- **Both ways, over the exact shape being shipped.** A guard is not believed
  -- here until it has been seen answering true and false over real values.
  if not semantic_private.private_observation_projection_is_valid_v03(
       'apple_calendar', 'calendar_event', 'sanitized_classification', 'scheduled',
       now(), repeat('a', 64), repeat('b', 64), repeat('c', 64), null, 'calendar-v03',
       '{"schema_version":"calendar-v03","record_kind":"calendar_classification",
         "classification_state":"candidate","artifact_type":"travel_itinerary",
         "place_key":"place:hong_kong"}'::jsonb,
       null, 1.0, 0.0, 'private_calendar_sanitized', false, 'active', null, null) then
    raise exception 'a candidate carrying place_key is refused';
  end if;

  -- The four-key shape must still pass, or every transit leg and every
  -- pre-existing row is refused.
  if not semantic_private.private_observation_projection_is_valid_v03(
       'apple_calendar', 'calendar_event', 'sanitized_classification', 'scheduled',
       now(), repeat('a', 64), repeat('b', 64), repeat('c', 64), null, 'calendar-v03',
       '{"schema_version":"calendar-v03","record_kind":"calendar_classification",
         "classification_state":"candidate","artifact_type":"travel_itinerary"}'::jsonb,
       null, 1.0, 0.0, 'private_calendar_sanitized', false, 'active', null, null) then
    raise exception 'the four-key candidate shape was broken by the patch';
  end if;

  -- A location string is not a place, and this is the property the whole
  -- widening rests on.
  if semantic_private.private_observation_projection_is_valid_v03(
       'apple_calendar', 'calendar_event', 'sanitized_classification', 'scheduled',
       now(), repeat('a', 64), repeat('b', 64), repeat('c', 64), null, 'calendar-v03',
       '{"schema_version":"calendar-v03","record_kind":"calendar_classification",
         "classification_state":"candidate","artifact_type":"travel_itinerary",
         "place_key":"洛杉磯 LAX"}'::jsonb,
       null, 1.0, 0.0, 'private_calendar_sanitized', false, 'active', null, null) then
    raise exception 'a location string was accepted as a place';
  end if;

  -- And nothing else may ride along beside it.
  if semantic_private.private_observation_projection_is_valid_v03(
       'apple_calendar', 'calendar_event', 'sanitized_classification', 'scheduled',
       now(), repeat('a', 64), repeat('b', 64), repeat('c', 64), null, 'calendar-v03',
       '{"schema_version":"calendar-v03","record_kind":"calendar_classification",
         "classification_state":"candidate","artifact_type":"travel_itinerary",
         "place_key":"place:hong_kong","title":"Flight to Hong Kong"}'::jsonb,
       null, 1.0, 0.0, 'private_calendar_sanitized', false, 'active', null, null) then
    raise exception 'an extra key rode along beside place_key';
  end if;

  select count(*) into places
  from ontology.concepts c
  join ontology.concept_revisions r on r.concept_id = c.id
  join ontology.versions v on v.id = r.ontology_version_id and v.status = 'published'
  where c.concept_key like 'place:%' and r.concept_kind = 'place';
  if places < 13 then
    raise exception 'expected at least 13 places (12 new plus italy), found %', places;
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           'ontology 0.16.0: a journey''s terminal place becomes a term'
         ) into enqueued;
  raise notice '0152: % places, % recompute job(s)', places, enqueued;
end;
$$;

commit;
