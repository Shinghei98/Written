-- 0435 — a trip is a term like any other.
--
-- **The owner's architectural objection, sustained: "why are calendar
-- terms styled differently — are you not implementing the calendar
-- branches parallelly into the global ontology graph?"** The graph
-- route existed all along — `assert_travel` (0157's design) writes an
-- `affinity_to` assertion per visited place onto the authored
-- `travel:` concepts, and those flow through `list_assertions` with
-- the same styling, blocks, confirm/suppress and revision discipline
-- as every other term. Two defects hid it:
--
--   * the scorer's place query read `normalized_payload->>'place_key'`,
--     a stamp only the dead AWS-era classifier ever wrote — so "Trip
--     to Cancún" and "Trip to Hong Kong" asserted off fossil rows
--     while St. Louis and every city the deterministic lane built
--     since never did (fixed in score.py 0.22.0, this change: the
--     places now come from the journey terminals and the booked
--     events' locations);
--   * my snapshot lane then drew the same cities a second time as
--     `visited_city` rows in a parallel style with parallel controls —
--     the special treatment the owner saw. That lane is deleted here.
--     Cities live in the term list; the event cards keep only what is
--     genuinely a record and not a concept — a dated booking.
--
-- The scorer version moves to 0.22.0, the old row retires in the same
-- migration (never two active), and the recompute is enqueued — the
-- three-lever rule: a model id is one of the levers, and this is it.

begin;

do $$
declare old_row ontology.model_versions%rowtype;
begin
  select * into old_row from ontology.model_versions
   where model_role = 'scorer' and status = 'active'
   order by created_at desc limit 1;
  if old_row.id is null then
    raise notice '0435: no active scorer stands; the model rows wait';
  else
    update ontology.model_versions set status = 'retired'
     where id = old_row.id;
    insert into ontology.model_versions
      (id, model_key, version, model_role, status, parameters)
    values (extensions.gen_random_uuid(), old_row.model_key,
            '0.22.0', 'scorer', 'active',
            coalesce(old_row.parameters, '{}'::jsonb)
              || jsonb_build_object('travel_places',
                   'asserted from journey terminals and booked-event '
                   || 'locations (typed candidate structures), not from '
                   || 'the retired payload place_key stamp'));
  end if;
end;
$$;

-- The snapshot keeps only the records: dated bookings. The cities are
-- terms now, and a term is not drawn twice in two styles.
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
         metrics = jsonb_build_object('item_count', booked_items,
                                      'group_count', 1)
   where id = snapshot_id;

  return jsonb_build_object('snapshot_id', snapshot_id,
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
    raise notice '0435: %', receipt;
  end loop;

  perform semantic_private.enqueue_recompute_on_analysis_change(
    '0435: scorer 0.22.0 — trips assert from the typed structures');
end;
$$;

commit;
