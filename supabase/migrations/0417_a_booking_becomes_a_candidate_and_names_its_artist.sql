-- 0417 — a booking becomes a candidate, and a ticket names its artist.
--
-- **Stages 2 and 3 of the calendar lane (owner: "why don't we build
-- stage 2 and 3 now", 2026-08-27), on 0416's classifications.**
--
-- **Stage 2 — the candidate writer.** Every `eligible_private_semantics`
-- classification of the two commercial classes becomes a
-- `booked_activity_candidates` row under 0045's own guard: predicate
-- paired to class (`booked_event` <-> public_ticketed_event,
-- `scheduled_dining` <-> commercial_reservation), lineage HMAC copied
-- from the source observation (the guard verifies the copy), targets
-- the constraint's own default hubs until an external binding exists.
-- `booking_state` is `past_scheduled` — the sanitized projection holds
-- no event date, and "was scheduled" is the claim the evidence
-- licenses; `planned` would assert a future nobody read.
-- Travel-itinerary candidates wait for the journey builder: their table
-- demands a stitched journey and a destination place, and stitching is
-- its own build.
--
-- **Stage 3 — the ticket names its artist (0157's missing writer).**
-- For each `booked_event` candidate, the event's own text is matched
-- against the catalogue's creator-kind labels — exact substring,
-- normalized, labels of four+ characters so IVE cannot hide inside
-- LIVE — and each match becomes a `booked_public_event_about`
-- assertion on the artist. Recognized by predicate, never by evidence
-- rows, exactly as 0157 said the design wanted; scored by the scorer's
-- new calendar block (same change) from the count of supporting
-- bookings; surfaced by `list_assertions` as any creator-kind claim.
-- The icebreaker never sees it (calendar-derived surface rules stand).
--
-- Ends with the recompute enqueue.

begin;

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
         o.content_lineage_hmac,
         case o.action_type when 'booked' then 'booked' else 'scheduled' end,
         'past_scheduled', 1.0, 1.0, 1.0, 'hub'
    from semantic_private.calendar_event_classifications c
    join semantic_private.observations o
      on o.id = c.observation_id and o.user_id = c.user_id
   where c.disposition = 'eligible_private_semantics'
     and c.event_class in ('public_ticketed_event', 'commercial_reservation')
     and o.lifecycle_state = 'active'
     -- A legacy observation without a lineage HMAC cannot satisfy the
     -- guard's lineage match and cannot be a candidate; skipped, counted.
     and o.content_lineage_hmac is not null
     and not exists (
       select 1 from semantic_private.booked_activity_candidates b
        where b.calendar_classification_id = c.id and b.user_id = c.user_id);
  get diagnostics written = row_count;
  return jsonb_build_object('candidates_written', written,
    'skipped_no_lineage', (
      select count(*) from semantic_private.calendar_event_classifications c2
      join semantic_private.observations o2
        on o2.id = c2.observation_id and o2.user_id = c2.user_id
      where c2.disposition = 'eligible_private_semantics'
        and c2.event_class in ('public_ticketed_event', 'commercial_reservation')
        and o2.content_lineage_hmac is null));
end;
$function$;

create or replace function semantic_private.write_booked_event_assertions()
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

  with event_texts as (
    select b.user_id,
           lower(convert_from(e.encrypted_text, 'utf8')) as text
      from semantic_private.booked_activity_candidates b
      join semantic_private.source_text_evidence e
        on e.observation_id = b.source_observation_id
       and e.user_id = b.user_id
       and e.refresh_status = 'current' and e.deleted_at is null
       and e.encryption_key_version = 'ris_lab_plaintext_v1'
     where b.predicate_key = 'booked_event'
  ),
  artists as (
    select distinct t.user_id, l.concept_id
      from event_texts t
      join ontology.concept_labels l
        on l.ontology_version_id = published_version
       and l.status = 'active'
       and length(l.normalized_label) >= 4
       and position(l.normalized_label in t.text) > 0
      join ontology.concept_revisions r
        on r.concept_id = l.concept_id
       and r.ontology_version_id = published_version
       and r.status = 'active' and r.concept_kind = 'creator'
  )
  insert into semantic_private.user_assertions
    (user_id, predicate_key, concept_id, created_ontology_version_id,
     assertion_origin, machine_state)
  select a.user_id, 'booked_public_event_about', a.concept_id,
         published_version, 'inferred', 'eligible'
    from artists a
   where not exists (
     select 1 from semantic_private.user_assertions ua
      where ua.user_id = a.user_id
        and ua.predicate_key = 'booked_public_event_about'
        and ua.concept_id = a.concept_id);
  get diagnostics written = row_count;
  return jsonb_build_object('artist_assertions_written', written);
end;
$function$;

revoke execute on function semantic_private.build_booked_activity_candidates()
  from public, anon, authenticated;
revoke execute on function semantic_private.write_booked_event_assertions()
  from public, anon, authenticated;
grant execute on function semantic_private.build_booked_activity_candidates()
  to semantic_worker;
grant execute on function semantic_private.write_booked_event_assertions()
  to semantic_worker;

do $$
declare r1 jsonb; r2 jsonb;
begin
  select semantic_private.build_booked_activity_candidates() into r1;
  select semantic_private.write_booked_event_assertions() into r2;
  perform semantic_private.enqueue_recompute_on_analysis_change(
    '0417: calendar stages 2-3 — ' || (r1 ->> 'candidates_written')
    || ' candidate(s), ' || (r2 ->> 'artist_assertions_written')
    || ' ticket-named artist assertion(s)');
  raise notice '0417: % %', r1, r2;
end;
$$;

commit;
