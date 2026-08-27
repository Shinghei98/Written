-- 0425 — the ticket marker is a rule.
--
-- **The owner's second calendar control (Cancún) caught the residue.**
-- The genuine trip lives in a row titled "Ticket: Chichén Itzá Premier
-- Tour …" — classified `unknown`/`review`, because the registry knew
-- "ticketmaster" and "concert" but not the marker Apple Calendar itself
-- writes on every ticketing-email event: the `Ticket:` title prefix,
-- the same fact the distiller stamps `booked=1` for. That prefix is
-- structural — the calendar app's own booking vocabulary, not a venue
-- name — so it joins the authored registry as a rule any user's rows
-- match. Priority 35, deliberately behind travel's 30: "Ticket:
-- Eurostar to Paris" is an itinerary first and a ticket second.
--
-- Two things this does and one it does not:
--   * the review residue is re-asked — any `unknown`/`review` verdict a
--     registered pattern now answers is updated in place (a
--     deterministic verdict is a function of the entry alone; the
--     original insert-only pass never revisits, so the re-ask is the
--     registry growing, not the classifier changing its mind);
--   * the fresh-only builders then run: the newly eligible rows get
--     booked candidates, and the snapshots rebuild for whoever gained
--     one.
--   * it does NOT put Cancún on the travel pane. The word "Cancún"
--     lives in the event's *location* field, and the RIS filing (0309)
--     filed titles only — the location joining the filed evidence is an
--     extraction-time decision and is booked with the v21 corpus run,
--     not smuggled in as a second evidence row here.
--
-- Ends with the recompute enqueue.

begin;

insert into semantic_private.calendar_class_patterns
  (pattern, event_class, disposition, priority, pattern_set)
select '^ticket:', 'public_ticketed_event', 'eligible_private_semantics',
       35, 'calendar-patterns-v1'
 where not exists (
   select 1 from semantic_private.calendar_class_patterns
    where pattern = '^ticket:');

-- Re-ask the review residue against the grown registry. Scoped to the
-- deterministic model's own verdicts: a model-lane `review` (when that
-- lane exists) is a judgement, and this pass may not overwrite one.
with readable as (
  select c.id as cid,
         lower(convert_from(e.encrypted_text, 'utf8')) as text
    from semantic_private.calendar_event_classifications c
    join ontology.model_versions m
      on m.id = c.classifier_model_id
     and m.model_key = 'written-deterministic-rules'
    join semantic_private.observations o
      on o.id = c.observation_id and o.user_id = c.user_id
     and o.lifecycle_state = 'active'
    join semantic_private.source_text_evidence e
      on e.observation_id = c.observation_id and e.user_id = c.user_id
     and e.refresh_status = 'current' and e.deleted_at is null
     and e.encryption_key_version = 'ris_lab_plaintext_v1'
   where c.disposition = 'review' and c.event_class = 'unknown'
),
verdicts as (
  select r.cid, p.event_class, p.disposition
    from readable r
    join lateral (
      select cp.event_class, cp.disposition
        from semantic_private.calendar_class_patterns cp
       where r.text ~* cp.pattern
       order by cp.priority, cp.id limit 1
    ) p on true
)
update semantic_private.calendar_event_classifications c
   set event_class = v.event_class, disposition = v.disposition
  from verdicts v
 where v.cid = c.id;

-- **A rebuild at an unchanged revision collided with its own
-- predecessor.** 0424's builder stales the prior ready snapshot, but the
-- unique key (user, input_revision, presentation_version) spans states,
-- so rebuilding before the revision moves is refused by the row it just
-- staled. A snapshot is a presentation cache, not evidence: the
-- same-revision predecessor is strictly superseded, so it is deleted
-- (items first — the FK does not cascade), while stale rows from *older*
-- revisions keep recording what was once shown.
create or replace function semantic_private.build_memories_snapshot(p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  builder_id uuid;
  published_version uuid;
  revision_value bigint;
  snapshot_id uuid;
  travel_items integer := 0;
  booked_items integer := 0;
begin
  select id into builder_id from ontology.model_versions
   where model_role = 'memories_builder' and status = 'active'
   order by created_at desc limit 1;
  select id into published_version from ontology.versions
   where status = 'published';
  select revision into revision_value
    from semantic_private.user_state_versions where user_id = p_user;

  update semantic_private.memories_snapshots
     set state = 'stale'
   where user_id = p_user and state = 'ready';

  delete from semantic_private.memories_snapshot_items i
   using semantic_private.memories_snapshots s
   where s.id = i.snapshot_id and s.user_id = p_user
     and s.input_revision = coalesce(revision_value, 0)
     and s.presentation_version = 'calendar-cards-v1';
  delete from semantic_private.memories_snapshots
   where user_id = p_user
     and input_revision = coalesce(revision_value, 0)
     and presentation_version = 'calendar-cards-v1';

  insert into semantic_private.memories_snapshots
    (user_id, ontology_version_id, builder_model_id, input_revision,
     presentation_version, state)
  values (p_user, published_version, builder_id, coalesce(revision_value, 0),
          'calendar-cards-v1', 'building')
  returning id into snapshot_id;

  insert into semantic_private.memories_snapshot_items
    (snapshot_id, user_id, scheduled_travel_candidate_id, item_key,
     item_kind, display_label, rank)
  select snapshot_id, c.user_id, c.id, 'travel:' || c.id::text,
         'scheduled_travel_candidate', 'pending',
         row_number() over (order by c.created_at desc)
    from semantic_private.scheduled_travel_candidates c
   where c.user_id = p_user
     and c.candidate_state in ('candidate', 'eligible')
     and semantic_private.scheduled_travel_candidate_is_current_v03(
           c.id, c.user_id);
  get diagnostics travel_items = row_count;

  insert into semantic_private.memories_snapshot_items
    (snapshot_id, user_id, booked_activity_candidate_id, item_key,
     item_kind, display_label, rank)
  select snapshot_id, b.user_id, b.id, 'booked:' || b.id::text,
         'booked_activity_candidate', 'pending',
         1000 + row_number() over (order by b.created_at desc)
    from semantic_private.booked_activity_candidates b
   where b.user_id = p_user
     and b.booking_state <> 'cancelled'
     and semantic_private.calendar_classification_is_current_v03(
           b.calendar_classification_id, b.user_id,
           b.source_observation_id, b.ontology_version_id);
  get diagnostics booked_items = row_count;

  update semantic_private.memories_snapshots
     set state = 'ready', finished_at = now(),
         metrics = jsonb_build_object('item_count',
                                      travel_items + booked_items,
                                      'group_count', 2)
   where id = snapshot_id;

  return jsonb_build_object('snapshot_id', snapshot_id,
                            'travel_items', travel_items,
                            'booked_items', booked_items);
end;
$function$;

do $$
declare reclassified integer; booked jsonb; u record; receipt jsonb;
begin
  select count(*) into reclassified
    from semantic_private.calendar_event_classifications
   where disposition = 'eligible_private_semantics'
     and event_class = 'public_ticketed_event';

  select semantic_private.build_booked_activity_candidates() into booked;
  raise notice '0425: booked %', booked;

  for u in select distinct user_id from (
    select user_id from semantic_private.scheduled_travel_candidates
    union select user_id from semantic_private.booked_activity_candidates) x
  loop
    select semantic_private.build_memories_snapshot(u.user_id) into receipt;
    raise notice '0425: snapshot %', receipt;
  end loop;

  perform semantic_private.enqueue_recompute_on_analysis_change(
    '0425: the ticket-prefix rule lands, ' || (booked ->> 'candidates_written')
    || ' new booked candidate(s), snapshots rebuilt');
end;
$$;

commit;
