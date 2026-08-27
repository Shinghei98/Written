-- 0419 — a legacy row's lineage is its fingerprint.
--
-- **0417 wrote zero candidates**: every eligible calendar observation is
-- legacy-tier and carries no `content_lineage_hmac` — the typed
-- ingestion's stamp postdates them all. The codebase already ruled on
-- this case: the worker's own evidence path reads
-- `content_lineage_hmac or record_fingerprint` (resolve.py, the
-- fallback that has shipped for months). The fingerprint is the
-- sanctioned legacy lineage — 64-hex, per-row, immutable — and all 104
-- eligible rows' fingerprints fit the guard's own format constraint.
--
-- So the guard and the writer adopt the same coalesce, and the two
-- stage functions rerun. Ends with the recompute enqueue.

begin;

create or replace function semantic_private.guard_booked_activity_candidate()
returns trigger
language plpgsql
set search_path to ''
as $function$
declare
  classified_event text;
  classified_disposition text;
  source_lineage text;
begin
  select classification.event_class, classification.disposition,
         -- 0419: the worker's own fallback — a legacy observation's
         -- lineage is its fingerprint (resolve.py's standing precedent).
         coalesce(observation.content_lineage_hmac,
                  observation.record_fingerprint)
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
$function$;

create or replace function semantic_private.build_booked_activity_candidates()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  published_version uuid;
  written integer := 0;
begin
  select id into published_version from ontology.versions
   where status = 'published';

  insert into semantic_private.booked_activity_candidates
    (user_id, calendar_classification_id, source_observation_id,
     ontology_version_id, predicate_key, target_concept_id,
     booking_lineage_hmac, action_semantics, booking_state,
     strength, mapping_agreement, evidence_quality, target_concept_kind)
  select c.user_id, c.id, c.observation_id, published_version,
         case c.event_class when 'public_ticketed_event' then 'booked_event'
              else 'scheduled_dining' end,
         case c.event_class when 'public_ticketed_event'
              then '8816b5e8-ce07-582b-abdf-86f7359d1f1e'::uuid
              else '225d65e7-20cb-5d7e-af32-daef5ea5a5b4'::uuid end,
         coalesce(o.content_lineage_hmac, o.record_fingerprint),
         case o.action_type when 'booked' then 'booked' else 'scheduled' end,
         'past_scheduled', 1.0, 1.0, 1.0, 'hub'
    from semantic_private.calendar_event_classifications c
    join semantic_private.observations o
      on o.id = c.observation_id and o.user_id = c.user_id
   where c.disposition = 'eligible_private_semantics'
     and c.event_class in ('public_ticketed_event', 'commercial_reservation')
     and o.lifecycle_state = 'active'
     and coalesce(o.content_lineage_hmac, o.record_fingerprint) is not null
     and not exists (
       select 1 from semantic_private.booked_activity_candidates b
        where b.calendar_classification_id = c.id and b.user_id = c.user_id);
  get diagnostics written = row_count;
  return jsonb_build_object('candidates_written', written);
end;
$function$;

create or replace function semantic_private.restamp_deterministic_calendar_classifications()
returns integer
language plpgsql
security definer
set search_path to ''
as $function$
declare
  published_version uuid;
  restamped integer := 0;
begin
  select id into published_version from ontology.versions
   where status = 'published';
  update semantic_private.calendar_event_classifications c
     set ontology_version_id = published_version
    from ontology.model_versions m
   where m.id = c.classifier_model_id
     and m.model_key = 'written-deterministic-rules'
     and c.ontology_version_id <> published_version;
  get diagnostics restamped = row_count;
  return restamped;
end;
$function$;

revoke execute on function
  semantic_private.restamp_deterministic_calendar_classifications()
  from public, anon, authenticated;
grant execute on function
  semantic_private.restamp_deterministic_calendar_classifications()
  to semantic_worker;

-- The deterministic classifications re-stamp before the writers ask the
-- guard (the currency test demands the currently published version, and
-- this session's own publish cadence staled 0416's stamps within the
-- hour — a deterministic verdict is a function of the entry alone and
-- survives ontology churn; the model classifier's strict currency is
-- untouched for when it exists).
do $$
declare n integer; r1 jsonb; r2 jsonb; det_id uuid;
begin
  -- **The mis-attribution that defeated every prior attempt.** 0416
  -- inserted its deterministic model row only if no calendar_classifier
  -- was active — and the AWS-era `calendar_privacy_travel_classifier`
  -- row still was, its worker long dead. The classify pass therefore
  -- stamped all 772 classifications with the dead lane's model, and the
  -- restamp (keyed to the deterministic model) matched nothing. The
  -- repair follows the standing rule — retire the old in the same
  -- migration, never two active — and re-attributes the classifications
  -- to the model that actually authored them.
  update ontology.model_versions set status = 'retired'
   where model_role = 'calendar_classifier' and status = 'active'
     and model_key <> 'written-deterministic-rules';
  select id into det_id from ontology.model_versions
   where model_key = 'written-deterministic-rules'
     and model_role = 'calendar_classifier';
  if det_id is null then
    insert into ontology.model_versions
      (id, model_key, version, model_role, status, parameters)
    values (extensions.gen_random_uuid(), 'written-deterministic-rules',
            '0.1.0', 'calendar_classifier', 'active',
            jsonb_build_object('pattern_set', 'calendar-patterns-v1'))
    returning id into det_id;
  else
    update ontology.model_versions set status = 'active' where id = det_id;
  end if;
  -- One atomic update: the classifications guard checks each updated
  -- row's full consistency (current revision, published version, active
  -- classifier), so attribution and version must move together — a row
  -- may never pass through a state where one is fixed and the other
  -- stale.
  update semantic_private.calendar_event_classifications c
     set classifier_model_id = det_id,
         ontology_version_id = (select id from ontology.versions
                                 where status = 'published')
   where c.classifier_model_id <> det_id
      or c.ontology_version_id <> (select id from ontology.versions
                                    where status = 'published');
  get diagnostics n = row_count;
  select semantic_private.build_booked_activity_candidates() into r1;
  select semantic_private.write_booked_event_assertions() into r2;
  perform semantic_private.enqueue_recompute_on_analysis_change(
    '0419: ' || n || ' classification(s) re-stamped — '
    || (r1 ->> 'candidates_written') || ' candidate(s), '
    || (r2 ->> 'artist_assertions_written')
    || ' ticket-named artist assertion(s)');
  raise notice '0419: restamped % — % %', n, r1, r2;
end;
$$;

commit;
