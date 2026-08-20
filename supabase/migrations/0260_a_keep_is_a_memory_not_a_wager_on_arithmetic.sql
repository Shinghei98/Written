-- 0260 — a keep is a Memory, not a wager on arithmetic.
--
-- The three-lane contract (§9.1, §9.4, §7.1) is explicit: keep confirms the
-- term for THIS user and creates or updates their Memory — user-confirmed
-- affinity, the same authority class as a term somebody typed. The 0.35 bar
-- gates INFERRED assertions; a person's own decision was never supposed to
-- wait on it, and the memo's "no false Memory is forced" clause governs the
-- inferred lane, not the confirmed one. So the mint processor, having given
-- the kept term its global identity, now finishes the user's half: the same
-- three writes `api.add_assertion` performs for an explicit addition —
-- user_assertions (explicit_addition, eligible), feedback_events
-- (explicit_add), assertion_preferences (confirmed) — performed for the
-- keeping user with the mint request's own id as the idempotency event key.
--
-- What this does NOT do, per the contract's critical separation: it verifies
-- no relation, promotes no candidate edge, and grants nothing to any other
-- user — they resolve to the same global identity but receive no affinity
-- without their own evidence and confirmation.

create or replace function semantic_private.confirm_kept_memory(
  p_user_id uuid, p_concept_id uuid, p_mint_request_id uuid)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_version_id uuid;
  v_assertion_id uuid;
  v_event_id uuid;
begin
  select id into strict v_version_id
    from ontology.versions where status = 'published';

  -- Idempotent on the mint request: a reprocessed batch finds its event and
  -- stops, exactly as add_assertion treats a repeated client_event_id.
  select assertion_id into v_assertion_id
    from semantic_private.feedback_events
   where user_id = p_user_id and client_event_id = p_mint_request_id;
  if found then
    return v_assertion_id;
  end if;

  insert into semantic_private.user_assertions (
    user_id, predicate_key, concept_id, user_term_id,
    created_ontology_version_id, assertion_origin, machine_state
  ) values (
    p_user_id, 'affinity_to', p_concept_id, null,
    v_version_id, 'explicit_addition', 'eligible'
  )
  on conflict (user_id, predicate_key, concept_id)
    where concept_id is not null
  do update set
    created_ontology_version_id = excluded.created_ontology_version_id,
    assertion_origin = 'explicit_addition',
    source_semantic_run_id = null,
    machine_state = 'eligible',
    updated_at = now()
  returning id into v_assertion_id;

  insert into semantic_private.feedback_events (
    user_id, assertion_id, action, label_semantics, client_event_id,
    ontology_version_id, context
  ) values (
    p_user_id, v_assertion_id, 'explicit_add', 'explicit_positive',
    p_mint_request_id, v_version_id,
    jsonb_build_object('surface', 'memories',
                       'origin', 'user_kept_qwen_discovery',
                       'mint_request_id', p_mint_request_id)
  ) returning id into v_event_id;

  insert into semantic_private.assertion_preferences (
    assertion_id, user_id, display_state, last_feedback_event_id
  ) values (v_assertion_id, p_user_id, 'confirmed', v_event_id)
  on conflict (assertion_id, user_id) do update
  set display_state = 'confirmed',
      last_feedback_event_id = excluded.last_feedback_event_id,
      updated_at = now();

  return v_assertion_id;
end;
$$;

revoke all on function
  semantic_private.confirm_kept_memory(uuid, uuid, uuid) from public;

-- The processor finishes the user's half after the identity exists. The
-- function is redefined in full (its body is 0258's with one addition), so
-- the file and the deployment cannot drift the way a regexp patch could.
create or replace function semantic_private.mint_from_kept_requests()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  current_version text;
  next_version    text;
  new_version_id  uuid;
  to_mint  integer := 0;
  to_link  integer := 0;
  refused  integer := 0;
  bumped   integer := 0;
  confirmed integer := 0;
  kept record;
begin
  select version into current_version
    from ontology.versions where status = 'published';
  if current_version is null then
    raise exception 'mint_from_kept_requests: no published ontology version';
  end if;

  drop table if exists kept_plan;
  create temporary table kept_plan on commit drop as
  with requests as (
    select r.id as request_id, r.user_id, r.review_item_id, r.candidate_id,
           r.provisional_entity_id, r.concept_id as candidate_concept_id,
           r.requested_label, r.requested_family, r.origin,
           case when r.origin = 'edit'
                then lower(regexp_replace(btrim(r.requested_label), '\s+', ' ', 'g'))
                else coalesce(p.normalized_label,
                              lower(regexp_replace(btrim(r.requested_label), '\s+', ' ', 'g')))
           end as normalized,
           case r.requested_family
             when 'person' then 'creator' when 'group' then 'creator'
             when 'organization' then 'creator'
             when 'sport' then 'activity' when 'activity' then 'activity'
             when 'idea' then 'topic' when 'culture' then 'topic'
             when 'event' then 'topic'
             else 'work'
           end as concept_kind
      from semantic_private.mint_requests r
      left join semantic_private.provisional_entities p
        on p.id = r.provisional_entity_id
     where r.status = 'pending'
       for update of r skip locked
  ), revalidated as (
    select q.*,
           exists (
             select 1 from semantic_private.calibration_effective_decisions d
              where d.review_item_id = q.review_item_id
                and d.effective_action in ('keep', 'edit')
           ) as decision_stands,
           not exists (
             select 1 from semantic_private.candidate_support_links l
             join semantic_private.observations o on o.id = l.observation_id
             where l.candidate_id = q.candidate_id
               and (not (o.source_code = any (semantic_private.model_input_source_codes()))
                    or o.lifecycle_state <> 'active')
           ) as sources_stand
      from requests q
  ), disposed as (
    select v.*,
           case
             when not v.decision_stands then 'refused:decision_superseded'
             when not v.sources_stand   then 'refused:source_ineligible_or_stale'
             when v.candidate_concept_id is not null then 'link_existing'
             when same_kind.concepts > 1 then 'refused:ambiguous_vocabulary'
             when same_kind.concept_id is not null then 'link'
             when other_kind.held then 'refused:label_collision_other_kind'
             else 'mint'
           end as disposition,
           coalesce(v.candidate_concept_id, same_kind.concept_id) as link_concept_id
      from revalidated v
      left join lateral (
        select min(l.concept_id::text)::uuid as concept_id,
               count(distinct l.concept_id) as concepts
          from ontology.concept_labels l
          join ontology.versions cv
            on cv.id = l.ontology_version_id and cv.version = current_version
          join ontology.concept_revisions cr
            on cr.ontology_version_id = cv.id and cr.concept_id = l.concept_id
         where l.status = 'active' and cr.status = 'active'
           and l.normalized_label = v.normalized
           and cr.concept_kind = v.concept_kind
      ) same_kind on true
      left join lateral (
        select exists (
          select 1 from ontology.concept_labels l
            join ontology.versions cv
              on cv.id = l.ontology_version_id and cv.version = current_version
            join ontology.concept_revisions cr
              on cr.ontology_version_id = cv.id and cr.concept_id = l.concept_id
           where l.status = 'active' and cr.status = 'active'
             and l.normalized_label = v.normalized
             and cr.concept_kind <> v.concept_kind
        ) as held
      ) other_kind on true
  )
  select * from disposed;

  select count(*) filter (where disposition = 'mint'),
         count(*) filter (where disposition like 'link%'),
         count(*) filter (where disposition like 'refused%')
    into to_mint, to_link, refused
    from kept_plan;

  if to_mint > 0 then
    next_version := split_part(current_version, '.', 1) || '.'
                 || split_part(current_version, '.', 2) || '.'
                 || (split_part(current_version, '.', 3)::integer + 1)::text;

    insert into ontology.versions (id, version, parent_version_id, status, description)
    select gen_random_uuid(), next_version, v.id, 'draft',
           'User-kept mint: ' || to_mint::text || ' concept(s) from kept Qwen discoveries.'
      from ontology.versions v where v.version = current_version
    on conflict (version) do nothing;

    select id into new_version_id from ontology.versions where version = next_version;
    if new_version_id is null then
      raise exception 'mint_from_kept_requests: could not open draft %', next_version;
    end if;

    perform ontology.copy_forward_version(
      (select id from ontology.versions where version = current_version),
      new_version_id);

    insert into ontology.concepts (id, concept_key)
    select gen_random_uuid(),
           k.concept_kind || ':kept_' || substr(md5(k.concept_kind || ':' || k.normalized), 1, 16)
      from kept_plan k where k.disposition = 'mint'
    on conflict (concept_key) do nothing;

    insert into ontology.concept_revisions (
      ontology_version_id, concept_id, preferred_label, concept_kind,
      definition, sensitivity, inference_policy, status, metadata)
    select distinct on (c.id)
           new_version_id, c.id, k.requested_label, k.concept_kind,
           null, 'ordinary', 'inferable', 'active',
           jsonb_build_object('origin', 'user_kept_qwen_discovery',
                              'mention_family', k.requested_family)
      from kept_plan k
      join ontology.concepts c
        on c.concept_key = k.concept_kind || ':kept_'
             || substr(md5(k.concept_kind || ':' || k.normalized), 1, 16)
     where k.disposition = 'mint'
    on conflict do nothing;

    insert into ontology.concept_labels (
      ontology_version_id, concept_id, label, normalized_label, locale,
      label_type, provenance_type, confidence, status, external_ref)
    select distinct on (c.id, kind.label_type)
           new_version_id, c.id, k.requested_label, k.normalized, 'und',
           kind.label_type, 'curated', 1.0, 'active',
           jsonb_build_object('origin', 'user_kept_qwen_discovery')
      from kept_plan k
      join ontology.concepts c
        on c.concept_key = k.concept_kind || ':kept_'
             || substr(md5(k.concept_kind || ':' || k.normalized), 1, 16)
     cross join (values ('preferred'), ('alternate')) as kind(label_type)
     where k.disposition = 'mint'
    on conflict do nothing;

    perform ontology.publish_version(new_version_id);
  end if;

  update semantic_private.provisional_entities p
     set redirect_concept_id = coalesce(
           k.link_concept_id,
           (select c.id from ontology.concepts c
             where c.concept_key = k.concept_kind || ':kept_'
                     || substr(md5(k.concept_kind || ':' || k.normalized), 1, 16))),
         identity_state = 'resolved_existing'
    from kept_plan k
   where p.id = k.provisional_entity_id
     and k.disposition in ('mint', 'link');

  update semantic_private.mint_requests r
     set status = case when k.disposition like 'refused%' then 'refused'
                       else 'completed' end,
         completed_at = now(),
         outcome = jsonb_build_object(
           'disposition', k.disposition,
           'concept_id', coalesce(
             k.link_concept_id,
             (select c.id from ontology.concepts c
               where c.concept_key = k.concept_kind || ':kept_'
                       || substr(md5(k.concept_kind || ':' || k.normalized), 1, 16))),
           'ontology_version', coalesce(next_version, current_version))
    from kept_plan k
   where r.id = k.request_id;

  -- **The user's half, finished (0260).** The keep becomes their Memory now,
  -- as user-confirmed affinity — not when arithmetic happens to agree.
  for kept in
    select k.request_id, k.user_id,
           coalesce(k.link_concept_id,
             (select c.id from ontology.concepts c
               where c.concept_key = k.concept_kind || ':kept_'
                       || substr(md5(k.concept_kind || ':' || k.normalized), 1, 16)))
             as concept_id
      from kept_plan k
     where k.disposition in ('mint', 'link', 'link_existing')
  loop
    if kept.concept_id is not null then
      perform semantic_private.confirm_kept_memory(
        kept.user_id, kept.concept_id, kept.request_id);
      confirmed := confirmed + 1;
    end if;
  end loop;

  update semantic_private.user_state_versions u
     set revision = revision + 1
   where u.user_id in (select distinct user_id from kept_plan
                        where disposition in ('mint', 'link', 'link_existing'));
  get diagnostics bumped = row_count;

  return jsonb_build_object(
    'minted', to_mint, 'linked', to_link, 'refused', refused,
    'memories_confirmed', confirmed, 'recomputes_bumped', bumped,
    'version', coalesce(next_version, current_version));
end;
$function$;

do $$
declare
  n integer;
begin
  -- Nothing confirmed before any keep: the new path writes only downstream
  -- of a completed request, and none exists on replay or before a decision.
  select count(*) into n from semantic_private.feedback_events
   where context ->> 'origin' = 'user_kept_qwen_discovery';
  if n > 0 then
    raise exception '0260: a kept Memory exists before any keep';
  end if;
end;
$$;
