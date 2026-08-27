-- 0430 — a city visited, and an event sorted.
--
-- **The owner's presentation ruling (2026-08-27), both halves:**
--
--   * **The travel card lists cities, one term each** — every city the
--     user has been to, from flight terminals and from where booked
--     events happened, deduplicated: one Cancún, one St. Louis, one
--     Hong Kong. A new `visited_city` item kind carries them; the
--     per-trip rows leave the card.
--   * **Booked events sort into five categories and only four show**:
--     festivals, restaurants, live shows (including tours),
--     exhibitions, and a catch-all `other` that is never drawn. The
--     first gate — public holidays out — is 0427's pattern tier and
--     runs before any of this by priority. Restaurants are structural
--     (a `commercial_reservation` is one by class); the ticketed
--     classes sort by an authored pattern registry, word-bounded so
--     "tour" never matches "tourism".
--
-- The guard stays the single author of labels and payloads; the
-- category travels as `subtitle` (already in the items' closed key
-- vocabulary) and the city label is the concept's own preferred label.

begin;

-- ---------------------------------------------------------------
-- Categories
-- ---------------------------------------------------------------

alter table semantic_private.booked_activity_candidates
  add column display_category text not null default 'other'
  check (display_category in
    ('festival', 'restaurant', 'live_show', 'exhibition', 'other'));

create table semantic_private.booked_event_category_patterns (
  id uuid primary key default gen_random_uuid(),
  pattern text not null,
  category text not null
    check (category in ('festival', 'live_show', 'exhibition')),
  priority integer not null,
  pattern_set text not null default 'event-categories-v1',
  unique (pattern)
);
alter table semantic_private.booked_event_category_patterns
  enable row level security;

insert into semantic_private.booked_event_category_patterns
  (pattern, category, priority)
values
  ('(concert|orchestra|symphony|philharmonic|recital|\mgig\M|\mtour\M|world tour|stand.?up|comedy|musical|theatre|theater|opera|ballet|\mlive\M|dj set|showcase|演唱會|演唱会|音樂會|音乐会|콘서트|ライブ)',
   'live_show', 10),
  ('(museum|exhibition|gallery|expo|biennale|art fair|博物館|博物馆|美術館|美术馆|展覽|展览|전시)',
   'exhibition', 20),
  ('(festival|carnival|\mfair\M|音樂節|音乐节|フェス|축제)',
   'festival', 30);

create or replace function semantic_private.booked_event_category(
  p_event_class text, p_title text)
returns text
language sql
stable
set search_path to ''
as $function$
  select case
    when p_event_class = 'commercial_reservation' then 'restaurant'
    else coalesce(
      (select cp.category
         from semantic_private.booked_event_category_patterns cp
        where p_title ~* cp.pattern
        order by cp.priority, cp.id limit 1),
      'other')
  end;
$function$;

-- Backfill over the standing candidates, from their filed titles.
update semantic_private.booked_activity_candidates b
   set display_category = semantic_private.booked_event_category(
         c.event_class,
         coalesce(convert_from(e.encrypted_text, 'utf8'), ''))
  from semantic_private.calendar_event_classifications c
  left join semantic_private.source_text_evidence e
    on e.observation_id = c.observation_id and e.user_id = c.user_id
   and e.refresh_status = 'current' and e.deleted_at is null
   and e.encryption_key_version = 'ris_lab_plaintext_v1'
 where c.id = b.calendar_classification_id and c.user_id = b.user_id;

-- Future candidates are born categorized.
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
     strength, mapping_agreement, evidence_quality, target_concept_kind,
     display_category)
  select c.user_id, c.id, c.observation_id, published_version,
         case c.event_class when 'public_ticketed_event' then 'booked_event'
              else 'scheduled_dining' end,
         case c.event_class when 'public_ticketed_event'
              then '8816b5e8-ce07-582b-abdf-86f7359d1f1e'::uuid
              else '225d65e7-20cb-5d7e-af32-daef5ea5a5b4'::uuid end,
         coalesce(o.content_lineage_hmac, o.record_fingerprint),
         case o.action_type when 'booked' then 'booked' else 'scheduled' end,
         'past_scheduled', 1.0, 1.0, 1.0, 'hub',
         semantic_private.booked_event_category(
           c.event_class,
           coalesce(convert_from(e.encrypted_text, 'utf8'), ''))
    from semantic_private.calendar_event_classifications c
    join semantic_private.observations o
      on o.id = c.observation_id and o.user_id = c.user_id
    left join semantic_private.source_text_evidence e
      on e.observation_id = c.observation_id and e.user_id = c.user_id
     and e.refresh_status = 'current' and e.deleted_at is null
     and e.encryption_key_version = 'ris_lab_plaintext_v1'
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

-- ---------------------------------------------------------------
-- The visited_city item kind
-- ---------------------------------------------------------------

alter table semantic_private.memories_snapshot_items
  drop constraint memories_snapshot_items_kind_check;
alter table semantic_private.memories_snapshot_items
  add constraint memories_snapshot_items_kind_check
  check (item_kind = any (array[
    'hub', 'subhub', 'summary', 'assertion', 'representative',
    'scheduled_travel_candidate', 'booked_activity_candidate',
    'visited_city']));

alter table semantic_private.memories_snapshot_items
  drop constraint memories_snapshot_items_assertion_shape_check;
alter table semantic_private.memories_snapshot_items
  add constraint memories_snapshot_items_assertion_shape_check
  check (
    (item_kind in ('assertion', 'representative')
       and assertion_id is not null
       and scheduled_travel_candidate_id is null
       and booked_activity_candidate_id is null)
    or (item_kind = 'scheduled_travel_candidate'
       and assertion_id is null
       and scheduled_travel_candidate_id is not null
       and booked_activity_candidate_id is null)
    or (item_kind = 'booked_activity_candidate'
       and assertion_id is null
       and scheduled_travel_candidate_id is null
       and booked_activity_candidate_id is not null)
    or (item_kind = 'visited_city'
       and assertion_id is null
       and ((scheduled_travel_candidate_id is null)
            <> (booked_activity_candidate_id is null)))
    or (item_kind in ('hub', 'subhub', 'summary')
       and assertion_id is null
       and scheduled_travel_candidate_id is null
       and booked_activity_candidate_id is null));

-- ---------------------------------------------------------------
-- The guard learns both rulings
-- ---------------------------------------------------------------

create or replace function semantic_private.guard_calendar_memories_item_v03()
returns trigger
language plpgsql
set search_path to ''
as $function$
declare
  controlled_payload jsonb;
  event_title text;
  event_date date;
  place_id uuid;
  place_label text;
  category text;
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
  elsif new.item_kind = 'visited_city' then
    if new.scheduled_travel_candidate_id is not null then
      select candidate.destination_place_concept_id into place_id
        from semantic_private.scheduled_travel_candidates candidate
       where candidate.id = new.scheduled_travel_candidate_id
         and candidate.user_id = new.user_id
         and semantic_private.scheduled_travel_candidate_is_current_v03(
           candidate.id, candidate.user_id);
    else
      select candidate.event_place_concept_id into place_id
        from semantic_private.booked_activity_candidates candidate
       where candidate.id = new.booked_activity_candidate_id
         and candidate.user_id = new.user_id
         and candidate.booking_state <> 'cancelled'
         and semantic_private.calendar_classification_is_current_v03(
           candidate.calendar_classification_id, candidate.user_id,
           candidate.source_observation_id, candidate.ontology_version_id);
    end if;
    select r.preferred_label into place_label
      from ontology.concept_revisions r
      join ontology.versions v
        on v.id = r.ontology_version_id and v.status = 'published'
     where r.concept_id = place_id
       and r.ontology_version_id = v.id
       and r.status = 'active' and r.concept_kind = 'place';
    if place_label is null then
      raise exception 'a visited city requires a live place behind a current candidate';
    end if;
    new.display_label := place_label;
    new.display_payload := jsonb_build_object(
      'template_key', 'visited_city',
      'wording_version', 'calendar-v03',
      'place_label', place_label,
      'source_badges', jsonb_build_array('Calendar'));
  elsif new.item_kind = 'booked_activity_candidate' then
    select candidate.display_payload, candidate.display_category
      into controlled_payload, category
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
    new.display_payload := controlled_payload || jsonb_build_object(
      'subtitle', case category
        when 'festival' then 'Festival'
        when 'restaurant' then 'Restaurant'
        when 'live_show' then 'Live show'
        when 'exhibition' then 'Exhibition'
        else 'Other' end);
  end if;
  return new;
end;
$function$;

-- ---------------------------------------------------------------
-- The builder draws the two rulings
-- ---------------------------------------------------------------

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

  -- Visited cities: one item per place, journeys and event locations
  -- pooled, most recent visit first. Each item carries one
  -- representative candidate for the guard to validate against.
  insert into semantic_private.memories_snapshot_items
    (snapshot_id, user_id, scheduled_travel_candidate_id,
     booked_activity_candidate_id, item_key, item_kind, display_label, rank)
  select snapshot_id, p_user, x.travel_id, x.booked_id,
         'city:' || x.place_id::text, 'visited_city', 'pending',
         row_number() over (order by x.latest desc nulls last, x.place_id)
    from (
      select place_id,
             (array_remove(array_agg(travel_id), null))[1] as travel_id,
             case when (array_remove(array_agg(travel_id), null))[1]
                    is not null
                  then null
                  else (array_remove(array_agg(booked_id), null))[1]
             end as booked_id,
             max(latest) as latest
        from (
          select c.destination_place_concept_id as place_id,
                 c.id as travel_id, null::uuid as booked_id,
                 (select max(o.occurred_at)
                    from semantic_private.travel_journey_segments js
                    join semantic_private.travel_segments s
                      on s.id = js.segment_id
                    join semantic_private.observations o
                      on o.id = s.source_observation_id
                   where js.journey_id = c.travel_journey_id) as latest
            from semantic_private.scheduled_travel_candidates c
           where c.user_id = p_user
             and c.candidate_state in ('candidate', 'eligible')
             and semantic_private.scheduled_travel_candidate_is_current_v03(
                   c.id, c.user_id)
          union all
          select b.event_place_concept_id, null::uuid, b.id,
                 (select o.occurred_at
                    from semantic_private.observations o
                   where o.id = b.source_observation_id)
            from semantic_private.booked_activity_candidates b
           where b.user_id = p_user
             and b.event_place_concept_id is not null
             and b.booking_state <> 'cancelled'
             and semantic_private.calendar_classification_is_current_v03(
                   b.calendar_classification_id, b.user_id,
                   b.source_observation_id, b.ontology_version_id)
        ) pooled
       where place_id is not null
       group by place_id
    ) x;
  get diagnostics travel_items = row_count;

  -- Booked events: categorized, deduplicated by title and date, and
  -- the catch-all is never drawn.
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
             and b.display_category <> 'other'
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
                            'visited_cities', travel_items,
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
    raise notice '0430: %', receipt;
  end loop;

  perform semantic_private.enqueue_recompute_on_analysis_change(
    '0430: journeys chained, cities pooled, events categorized');
end;
$$;

commit;
