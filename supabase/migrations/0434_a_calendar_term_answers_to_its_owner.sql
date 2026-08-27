-- 0434 — a calendar term answers to its owner.
--
-- **The owner's ruling: "these are real terms, why aren't they
-- editable."** The calendar rows had no controls because they were
-- presentation-cache items with no assertion identity — but the one
-- control that matters for a derived term is the one assertions
-- already have: *"don't show me this"*, a preference, not a diagnostic
-- and not a calibration vote (`assertion_preferences`' distinction: a
-- deterministic classification is not a model proposal, so a strike
-- here recalibrates nothing).
--
-- The suppression keys on **stable identity, never on the rebuildable
-- row**: a city is its place concept, a booked event is its booking
-- lineage — candidate ids are wiped on every journey rebuild (0429/
-- 0431 both did), and a preference that died with the candidate would
-- un-hide everything on the next rebuild. The builder consults the
-- preferences, so suppression survives every rebuild by construction.
--
-- Same restore shape as assertions: an undo in the moment, because
-- nothing lists what was hidden — the same standing gap, recorded once
-- in NEXT-STEPS for both surfaces.

begin;

create table semantic_private.calendar_memory_preferences (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  item_scope text not null check (item_scope in ('city', 'booked')),
  scope_key text not null,
  created_at timestamptz not null default now(),
  unique (user_id, item_scope, scope_key)
);
alter table semantic_private.calendar_memory_preferences
  enable row level security;

create or replace function api.suppress_calendar_memory(p_item_key text)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  uid uuid;
  scope text;
  key text;
begin
  perform semantic_private.assert_surface_allowed('memories');
  uid := auth.uid();
  if uid is null then
    raise exception 'not signed in';
  end if;
  -- The handle must name a row currently on this owner's own pane.
  if not exists (
    select 1 from semantic_private.memories_snapshot_items i
    join semantic_private.memories_snapshots s
      on s.id = i.snapshot_id and s.user_id = i.user_id
   where i.user_id = uid and s.state = 'ready'
     and i.item_key = p_item_key) then
    raise exception 'no such calendar memory';
  end if;

  if p_item_key like 'city:%' then
    scope := 'city';
    key := substring(p_item_key from 6);
    perform key::uuid;  -- malformed handles fail here, loudly
  elsif p_item_key like 'booked:%' then
    scope := 'booked';
    select b.booking_lineage_hmac into key
      from semantic_private.booked_activity_candidates b
     where b.id = substring(p_item_key from 8)::uuid and b.user_id = uid;
    if key is null then
      raise exception 'no such calendar memory';
    end if;
  else
    raise exception 'no such calendar memory';
  end if;

  insert into semantic_private.calendar_memory_preferences
    (user_id, item_scope, scope_key)
  values (uid, scope, key)
  on conflict (user_id, item_scope, scope_key) do nothing;

  perform semantic_private.build_memories_snapshot(uid);
end;
$function$;

create or replace function api.restore_calendar_memory(p_item_key text)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  uid uuid;
  key text;
begin
  perform semantic_private.assert_surface_allowed('memories');
  uid := auth.uid();
  if uid is null then
    raise exception 'not signed in';
  end if;
  if p_item_key like 'city:%' then
    delete from semantic_private.calendar_memory_preferences
     where user_id = uid and item_scope = 'city'
       and scope_key = substring(p_item_key from 6);
  elsif p_item_key like 'booked:%' then
    select b.booking_lineage_hmac into key
      from semantic_private.booked_activity_candidates b
     where b.id = substring(p_item_key from 8)::uuid and b.user_id = uid;
    delete from semantic_private.calendar_memory_preferences
     where user_id = uid and item_scope = 'booked' and scope_key = key;
  end if;
  perform semantic_private.build_memories_snapshot(uid);
end;
$function$;

-- Supabase's default privileges grant every new api function to anon
-- and authenticated; revoke anon by name (the standing lesson —
-- `revoke from public` leaves the direct grant untouched).
revoke execute on function api.suppress_calendar_memory(text) from anon;
revoke execute on function api.restore_calendar_memory(text) from anon;
grant execute on function api.suppress_calendar_memory(text)
  to authenticated;
grant execute on function api.restore_calendar_memory(text)
  to authenticated;

-- The builder consults the preferences, so a strike survives rebuilds.
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
    ) x
   where not exists (
     select 1 from semantic_private.calendar_memory_preferences p
      where p.user_id = p_user and p.item_scope = 'city'
        and p.scope_key = x.place_id::text);
  get diagnostics travel_items = row_count;

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
             and not exists (
               select 1 from semantic_private.calendar_memory_preferences p
                where p.user_id = p_user and p.item_scope = 'booked'
                  and p.scope_key = b.booking_lineage_hmac)
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

commit;
