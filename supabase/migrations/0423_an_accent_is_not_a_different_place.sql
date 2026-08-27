-- 0423 — an accent is not a different place.
--
-- **The owner's Cancún control caught it**: the place's labels carry
-- only the accented `cancún`, a calendar writes "Cancun", and a
-- byte-wise `position()` calls them strangers — so a genuine trip fell
-- out of the journey builder while Hong Kong sailed through. The class
-- is general (José, Málaga, München), so the fix is matching, not a
-- label: the `unaccent` extension installs (into `extensions`, the
-- schema every extension lives in here), and the journey builder folds
-- accents on both sides of every place comparison. The builder then
-- reruns for whatever the accent hole excluded.
--
-- Ends with the recompute enqueue.

begin;

create extension if not exists unaccent schema extensions;

create or replace function semantic_private.build_travel_journeys_deterministic()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  published_version uuid;
  itinerary record;
  place_one record;
  place_two record;
  n_places integer;
  seg_id uuid;
  journey_id uuid;
  built integer := 0;
  held_multi integer := 0;
  no_place integer := 0;
begin
  select id into published_version from ontology.versions
   where status = 'published';

  for itinerary in
    select distinct on (c.user_id,
                        coalesce(o.content_lineage_hmac, o.record_fingerprint))
           c.id as classification_id, c.observation_id, c.user_id,
           coalesce(o.content_lineage_hmac, o.record_fingerprint)
             as record_fingerprint,
           case o.action_type when 'booked' then 'booked' else 'scheduled' end
             as action_sem,
           extensions.unaccent(lower(convert_from(e.encrypted_text, 'utf8')))
             as text
      from semantic_private.calendar_event_classifications c
      join semantic_private.observations o
        on o.id = c.observation_id and o.user_id = c.user_id
       and o.lifecycle_state = 'active'
      join semantic_private.source_text_evidence e
        on e.observation_id = c.observation_id and e.user_id = c.user_id
       and e.refresh_status = 'current' and e.deleted_at is null
       and e.encryption_key_version = 'ris_lab_plaintext_v1'
     where c.disposition = 'eligible_private_semantics'
       and c.event_class = 'travel_itinerary'
       and not exists (
         select 1 from semantic_private.travel_segments s
          where s.calendar_classification_id = c.id and s.user_id = c.user_id)
       and not exists (
         select 1 from semantic_private.travel_segments s2
          where s2.user_id = c.user_id
            and s2.segment_lineage_hmac
                = coalesce(o.content_lineage_hmac, o.record_fingerprint))
     order by c.user_id,
              coalesce(o.content_lineage_hmac, o.record_fingerprint),
              c.id
  loop
    select count(distinct concept_id) into n_places from (
      select l.concept_id
        from ontology.concept_labels l
        join ontology.concept_revisions r
          on r.concept_id = l.concept_id
         and r.ontology_version_id = published_version
         and r.status = 'active' and r.concept_kind = 'place'
       where l.ontology_version_id = published_version and l.status = 'active'
         and (length(l.normalized_label) >= 4
              or l.normalized_label ~ '[^\x00-\x7F]')
         and position(extensions.unaccent(l.normalized_label)
               in itinerary.text) > 0) p;

    if n_places = 0 then
      no_place := no_place + 1;
      continue;
    elsif n_places > 2 then
      held_multi := held_multi + 1;
      continue;
    end if;

    select p.concept_id, min(p.pos) as first_pos into place_one from (
      select l.concept_id,
             position(extensions.unaccent(l.normalized_label)
               in itinerary.text) as pos
        from ontology.concept_labels l
        join ontology.concept_revisions r
          on r.concept_id = l.concept_id
         and r.ontology_version_id = published_version
         and r.status = 'active' and r.concept_kind = 'place'
       where l.ontology_version_id = published_version and l.status = 'active'
         and (length(l.normalized_label) >= 4
              or l.normalized_label ~ '[^\x00-\x7F]')
         and position(extensions.unaccent(l.normalized_label)
               in itinerary.text) > 0) p
     group by p.concept_id order by min(p.pos) desc limit 1;

    select p.concept_id into place_two from (
      select l.concept_id,
             position(extensions.unaccent(l.normalized_label)
               in itinerary.text) as pos
        from ontology.concept_labels l
        join ontology.concept_revisions r
          on r.concept_id = l.concept_id
         and r.ontology_version_id = published_version
         and r.status = 'active' and r.concept_kind = 'place'
       where l.ontology_version_id = published_version and l.status = 'active'
         and (length(l.normalized_label) >= 4
              or l.normalized_label ~ '[^\x00-\x7F]')
         and position(extensions.unaccent(l.normalized_label)
               in itinerary.text) > 0
         and l.concept_id <> place_one.concept_id) p
     group by p.concept_id order by min(p.pos) limit 1;

    insert into semantic_private.travel_segments
      (user_id, calendar_classification_id, source_observation_id,
       ontology_version_id, segment_lineage_hmac,
       origin_place_concept_id, destination_place_concept_id, segment_state)
    values (itinerary.user_id, itinerary.classification_id,
            itinerary.observation_id, published_version,
            itinerary.record_fingerprint,
            place_two.concept_id, place_one.concept_id, 'past_scheduled')
    returning id into seg_id;

    insert into semantic_private.travel_journeys
      (user_id, ontology_version_id, journey_lineage_hmac,
       journey_state, terminal_place_concept_id)
    values (itinerary.user_id, published_version,
            itinerary.record_fingerprint, 'past_scheduled',
            place_one.concept_id)
    returning id into journey_id;

    insert into semantic_private.travel_journey_segments
      (journey_id, user_id, ontology_version_id, segment_id, segment_role,
       segment_order)
    values (journey_id, itinerary.user_id, published_version, seg_id,
            'one_way', 1);

    insert into semantic_private.scheduled_travel_candidates
      (user_id, travel_journey_id, ontology_version_id,
       destination_place_concept_id, action_semantics,
       strength, mapping_agreement, evidence_quality)
    values (itinerary.user_id, journey_id, published_version,
            place_one.concept_id, itinerary.action_sem, 1.0, 1.0, 1.0);

    built := built + 1;
  end loop;

  return jsonb_build_object('journeys_built', built,
                            'held_multi_leg', held_multi,
                            'no_known_place', no_place);
end;
$function$;

do $$
declare receipt jsonb;
begin
  select semantic_private.build_travel_journeys_deterministic() into receipt;
  perform semantic_private.enqueue_recompute_on_analysis_change(
    '0423: accents fold — ' || (receipt ->> 'journeys_built')
    || ' more journey(s), ' || (receipt ->> 'held_multi_leg')
    || ' held, ' || (receipt ->> 'no_known_place') || ' unplaced');
  raise notice '0423: %', receipt;
end;
$$;

commit;
