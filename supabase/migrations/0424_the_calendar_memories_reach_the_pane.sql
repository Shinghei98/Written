-- 0424 — the calendar memories reach the pane.
--
-- **The owner: "build the snapshot builder" — and the missing reader
-- with it (2026-08-27).** The candidate lanes end fully dressed:
-- display payloads composed by the guards themselves, item labels
-- authored by `guard_calendar_memories_item_v03` on insert. What never
-- existed was (a) anything writing `memories_snapshots`, and (b) any
-- `api` function reading them — `build_memories` is the last of the
-- dead worker's job types this project needed. Three pieces:
--
-- 1. A registered `memories_builder` model (deterministic; a builder
--    that copies guard-authored payloads needs no parameters beyond its
--    name).
-- 2. `build_memories_snapshot(p_user)`: prior ready snapshots go stale;
--    a new snapshot collects every CURRENT calendar candidate — the
--    item guard re-verifies currency and composes each label — and goes
--    `ready` (the snapshot guard holds ready to the user's current
--    revision, so a stale build refuses rather than lies).
-- 3. `api.list_memories_snapshot()`: the reader, surface-guarded like
--    every memories read.
--
-- The iOS card that draws this ships in the same commit (Swift half).

begin;

do $$
begin
  if not exists (select 1 from ontology.model_versions
                  where model_role = 'memories_builder' and status = 'active') then
    insert into ontology.model_versions
      (id, model_key, version, model_role, status, parameters)
    values (extensions.gen_random_uuid(), 'written-deterministic-rules',
            '0.1.0', 'memories_builder', 'active',
            jsonb_build_object('note',
              'copies guard-authored candidate payloads into snapshot items'));
  end if;
end;
$$;

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
         -- The metrics vocabulary is closed (item_count, group_count,
         -- build_duration_ms, abstained_count); the split lives in the
         -- returned receipt, the row records the registered total.
         metrics = jsonb_build_object('item_count',
                                      travel_items + booked_items,
                                      'group_count', 2)
   where id = snapshot_id;

  return jsonb_build_object('snapshot_id', snapshot_id,
                            'travel_items', travel_items,
                            'booked_items', booked_items);
end;
$function$;

revoke execute on function semantic_private.build_memories_snapshot(uuid)
  from public, anon, authenticated;
grant execute on function semantic_private.build_memories_snapshot(uuid)
  to semantic_worker;

create or replace function api.list_memories_snapshot()
returns table(item_key text, item_kind text, display_label text,
              display_payload jsonb, rank integer)
language plpgsql
stable security definer
set search_path to ''
as $function$
begin
  perform semantic_private.assert_surface_allowed('memories');
  return query
  select i.item_key, i.item_kind, i.display_label, i.display_payload,
         i.rank
    from semantic_private.memories_snapshot_items i
    join semantic_private.memories_snapshots s
      on s.id = i.snapshot_id and s.user_id = i.user_id
   where i.user_id = auth.uid()
     and s.state = 'ready'
     and i.item_kind in ('scheduled_travel_candidate',
                         'booked_activity_candidate')
   order by i.rank;
end;
$function$;

revoke execute on function api.list_memories_snapshot() from public, anon;
grant execute on function api.list_memories_snapshot() to authenticated;

do $$
declare u record; receipt jsonb;
begin
  for u in select distinct user_id from (
    select user_id from semantic_private.scheduled_travel_candidates
    union select user_id from semantic_private.booked_activity_candidates) x
  loop
    select semantic_private.build_memories_snapshot(u.user_id) into receipt;
    raise notice '0424: %', receipt;
  end loop;
end;
$$;

commit;
