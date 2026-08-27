-- 0426 — the pane says what the calendar said.
--
-- **The owner opened the card and read "Booked event: Arts & live
-- culture" eleven times.** Two defects, both presentation: the 0419
-- builder points every ticketed event at one generic hub concept, so
-- the guard's `predicate_label: target_label` wording prints the hub's
-- name instead of the event's; and nothing deduplicates the Apple/
-- Google calendar overlap, so one diary read twice shows twice.
--
-- Memories is the owner's own surface — a calendar title shown back to
-- the person whose calendar it is breaks none of the four calendar
-- prohibitions, and naming the event is the whole reason the card
-- exists. So:
--   * the guard authors the label from the event's own filed text
--     ("Chichén Itzá Premier Tour …", the `Ticket:` marker stripped),
--     with the event's month from `occurred_at`; the generic wording
--     survives only as the fallback for evidence the lane cannot read
--     (the AWS key discipline — the RIS plaintext key version is the
--     only one a SQL reader may touch);
--   * travel labels carry the month too, so two genuine Los Angeles
--     trips stop reading as a stutter;
--   * the builder collapses duplicates where they are *shown*, by title
--     and event date — the standing calendar rule — and ranks by event
--     date, newest first, instead of by row creation.
--
-- The payload key vocabularies stay closed and untouched: the label is
-- authored text, and that is the column wording belongs in. No
-- recompute is enqueued — nothing the scorer reads moved.

begin;

create or replace function semantic_private.guard_calendar_memories_item_v03()
returns trigger
language plpgsql
set search_path to ''
as $function$
declare
  controlled_payload jsonb;
  event_title text;
  event_date date;
begin
  if new.item_kind = 'scheduled_travel_candidate' then
    select candidate.display_payload into controlled_payload
    from semantic_private.scheduled_travel_candidates as candidate
    where candidate.id = new.scheduled_travel_candidate_id
      and candidate.user_id = new.user_id
      and semantic_private.scheduled_travel_candidate_is_current_v03(
        candidate.id, candidate.user_id
      );
    if controlled_payload is null then
      raise exception 'Calendar Memory requires an eligible typed travel candidate';
    end if;
    select min(o.occurred_at)::date into event_date
      from semantic_private.scheduled_travel_candidates candidate
      join semantic_private.travel_journey_segments js
        on js.journey_id = candidate.travel_journey_id
      join semantic_private.travel_segments s on s.id = js.segment_id
      join semantic_private.observations o on o.id = s.source_observation_id
     where candidate.id = new.scheduled_travel_candidate_id
       and candidate.user_id = new.user_id;
    new.display_label := 'Scheduled travel to ' ||
      (controlled_payload ->> 'place_label') ||
      coalesce(' · ' || to_char(event_date, 'Mon YYYY'), '');
    new.display_payload := controlled_payload;
  elsif new.item_kind = 'booked_activity_candidate' then
    select candidate.display_payload into controlled_payload
    from semantic_private.booked_activity_candidates as candidate
    where candidate.id = new.booked_activity_candidate_id
      and candidate.user_id = new.user_id
      and candidate.booking_state <> 'cancelled'
      and semantic_private.calendar_classification_is_current_v03(
        candidate.calendar_classification_id, candidate.user_id,
        candidate.source_observation_id, candidate.ontology_version_id
      );
    if controlled_payload is null then
      raise exception 'Calendar Memory requires a current typed booking candidate';
    end if;
    select nullif(trim(regexp_replace(
             convert_from(e.encrypted_text, 'utf8'),
             '^\s*[Tt]icket:\s*', '')), ''),
           o.occurred_at::date
      into event_title, event_date
      from semantic_private.booked_activity_candidates candidate
      join semantic_private.observations o
        on o.id = candidate.source_observation_id
      left join semantic_private.source_text_evidence e
        on e.observation_id = o.id and e.user_id = o.user_id
       and e.refresh_status = 'current' and e.deleted_at is null
       and e.encryption_key_version = 'ris_lab_plaintext_v1'
     where candidate.id = new.booked_activity_candidate_id
       and candidate.user_id = new.user_id;
    new.display_label := coalesce(event_title,
        (controlled_payload ->> 'predicate_label') || ': ' ||
        (controlled_payload ->> 'target_label')) ||
      coalesce(' · ' || to_char(event_date, 'Mon YYYY'), '');
    new.display_payload := controlled_payload;
  end if;
  return new;
end;
$function$;

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

  -- One row per (place, event date): the Apple/Google overlap collapses
  -- where it is shown, and two genuine trips to one city keep both rows.
  insert into semantic_private.memories_snapshot_items
    (snapshot_id, user_id, scheduled_travel_candidate_id, item_key,
     item_kind, display_label, rank)
  select snapshot_id, x.user_id, x.id, 'travel:' || x.id::text,
         'scheduled_travel_candidate', 'pending',
         row_number() over (order by x.event_date desc nulls last, x.id)
    from (
      select distinct on (c.display_payload ->> 'place_label', d.event_date)
             c.id, c.user_id, d.event_date
        from semantic_private.scheduled_travel_candidates c
        left join lateral (
          select min(o.occurred_at)::date as event_date
            from semantic_private.travel_journey_segments js
            join semantic_private.travel_segments s on s.id = js.segment_id
            join semantic_private.observations o
              on o.id = s.source_observation_id
           where js.journey_id = c.travel_journey_id) d on true
       where c.user_id = p_user
         and c.candidate_state in ('candidate', 'eligible')
         and semantic_private.scheduled_travel_candidate_is_current_v03(
               c.id, c.user_id)
       order by c.display_payload ->> 'place_label', d.event_date, c.id
    ) x;
  get diagnostics travel_items = row_count;

  -- One row per (title, event date), titled from the filed text where
  -- the lane can read it; unreadable evidence groups by its class label.
  insert into semantic_private.memories_snapshot_items
    (snapshot_id, user_id, booked_activity_candidate_id, item_key,
     item_kind, display_label, rank)
  select snapshot_id, x.user_id, x.id, 'booked:' || x.id::text,
         'booked_activity_candidate', 'pending',
         1000 + row_number() over (order by x.event_date desc nulls last, x.id)
    from (
      select distinct on (x0.title_key, x0.event_date)
             x0.id, x0.user_id, x0.event_date
        from (
          select b.id, b.user_id, t.event_date,
                 lower(coalesce(t.title, b.display_payload ->> 'target_label'))
                   as title_key
            from semantic_private.booked_activity_candidates b
            left join lateral (
              select nullif(trim(regexp_replace(
                       convert_from(e.encrypted_text, 'utf8'),
                       '^\s*[Tt]icket:\s*', '')), '') as title,
                     o.occurred_at::date as event_date
                from semantic_private.observations o
                left join semantic_private.source_text_evidence e
                  on e.observation_id = o.id and e.user_id = o.user_id
                 and e.refresh_status = 'current' and e.deleted_at is null
                 and e.encryption_key_version = 'ris_lab_plaintext_v1'
               where o.id = b.source_observation_id) t on true
           where b.user_id = p_user
             and b.booking_state <> 'cancelled'
             and semantic_private.calendar_classification_is_current_v03(
                   b.calendar_classification_id, b.user_id,
                   b.source_observation_id, b.ontology_version_id)
        ) x0
       order by x0.title_key, x0.event_date, x0.id
    ) x;
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
declare u record; receipt jsonb;
begin
  for u in select distinct user_id from (
    select user_id from semantic_private.scheduled_travel_candidates
    union select user_id from semantic_private.booked_activity_candidates) x
  loop
    select semantic_private.build_memories_snapshot(u.user_id) into receipt;
    raise notice '0426: %', receipt;
  end loop;
end;
$$;

commit;
