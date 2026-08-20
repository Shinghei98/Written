-- 0258 — Release D: a kept term becomes global vocabulary, through the same
-- door every minted concept has ever used.
--
-- `mint_from_kept_requests` is the catalogue processor the revised memo
-- names. It follows `mint_vocabulary_from_catalogue`'s proven shape rung for
-- rung — disposition plan against the published version, nothing-new means
-- no version, draft + five-table copy-forward, `ontology.publish_version`
-- (which serialises on `share row exclusive` and checks cycles), recompute
-- enqueue — because that function paid for its lessons one billing run at a
-- time and this one should not pay for them again. What differs is the
-- license: the only rows it reads are `mint_requests` created by an owner's
-- keep or edit, revalidated here against the effective-decision projection,
-- source licensing and observation currency. Qwen chose nothing in this
-- file; it cannot even see it.
--
-- Identity and collision rules (memo §3.7): the concept key is derived from
-- (family, normalized label), so two users keeping the same term converge on
-- one global concept by `on conflict` rather than racing into duplicates. A
-- normalized label already held by exactly one compatible-kind concept links
-- instead of minting; held by several, the request is refused `ambiguous_
-- vocabulary`; held by an incompatible kind, refused `label_collision_other_
-- kind` — homonyms are never merged and never silently minted over.
--
-- The confirmed evidence mapping (memo §5.4.2) is NOT written here: mappings
-- may only be written inside a running semantic run the user owns
-- (`guard_semantic_output_writable`), so the resolver writes them under
-- `mapping_method = 'user_confirmed_qwen_mint'` — widened below — on the
-- recompute this function enqueues. Keep → mint → mapping → scorer, each in
-- the room built for it.

-- 1. The scorer's door learns the new method name.
alter table semantic_private.observation_mappings
  drop constraint observation_mappings_mapping_method_check;
alter table semantic_private.observation_mappings
  add constraint observation_mappings_mapping_method_check
  check (mapping_method = any (array[
    'provider_id', 'curated_alias', 'provider_metadata', 'lexical',
    'embedding_candidate', 'external_candidate', 'graph_context',
    'user_correction', 'user_confirmed_qwen_mint']));

-- 2. The processor.
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
           -- The decision must still stand: the latest event for the review
           -- item is a keep or an edit, not a strike or a restore.
           exists (
             select 1 from semantic_private.calibration_effective_decisions d
              where d.review_item_id = q.review_item_id
                and d.effective_action in ('keep', 'edit')
           ) as decision_stands,
           -- Every supporting observation is licensed and still current.
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

    -- Copy-forward through the function built for it — `ontology.
    -- copy_forward_version` exists because a hand-written copy once forgot
    -- the fifth table, and `test_no_later_migration_hand_rolls_a_copy_forward`
    -- refuses any migration that writes the five inserts again (it refused
    -- this one's first draft, which is the guard working).
    perform ontology.copy_forward_version(
      (select id from ontology.versions where version = current_version),
      new_version_id);

    -- The new identities. Keyed on (kind, normalized label) so concurrent
    -- keeps of the same term converge on one concept.
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

    -- `curated`: a person decided this label. Both label types, or the
    -- resolver's bare-string emission never auto-accepts (0096's lesson).
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

    -- No `broader` parent: a user-kept term has no stated parent, and one
    -- parented to a guess is a false claim. Landing under "Other" is honest.

    perform ontology.publish_version(new_version_id);
  end if;

  -- Link every provisional to its concept — minted or matched — and complete
  -- the requests with a recorded outcome. Refusals are outcomes too.
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

  -- The recompute: a moved revision enqueues its own run (0131), which is
  -- where the resolver writes the confirmed mapping. Works identically for
  -- the pure-link case, which publishes no version.
  update semantic_private.user_state_versions u
     set revision = revision + 1
   where u.user_id in (select distinct user_id from kept_plan
                        where disposition in ('mint', 'link', 'link_existing'));
  get diagnostics bumped = row_count;

  return jsonb_build_object(
    'minted', to_mint, 'linked', to_link, 'refused', refused,
    'recomputes_bumped', bumped,
    'version', coalesce(next_version, current_version));
end;
$function$;

revoke all on function semantic_private.mint_from_kept_requests() from public;
grant execute on function semantic_private.mint_from_kept_requests()
  to semantic_worker;

-- 3. The job: enqueued by the request itself, handled by the worker.
create or replace function semantic_private.enqueue_mint_processing()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  insert into semantic_private.worker_jobs
    (job_type, user_id, payload, idempotency_key, available_at)
  values ('process_mint_requests', null,
          jsonb_build_object('mint_request_id', new.id),
          'process_mint_requests:' || new.id::text, now())
  on conflict (idempotency_key) do nothing;
  return new;
end;
$$;

create trigger mint_requests_enqueue_processing
  after insert on semantic_private.mint_requests
  for each row execute function semantic_private.enqueue_mint_processing();

-- The payload validator learns the new job type, by the same in-place
-- injection 0247 established: fetch the deployed body, add the arm before
-- `else`, re-execute. Replaying this file performs the same injection on the
-- replayed body, so file and deployment cannot drift here.
do $$
declare
  body text;
begin
  select pg_get_functiondef(p.oid) into strict body
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'semantic_private'
     and p.proname = 'worker_job_payload_is_valid_v03';
  if body not like '%process_mint_requests%' then
    body := replace(body,
      '    else
      return false;',
      '    when ''process_mint_requests'' then
      return semantic_private.worker_json_has_exact_keys_v03(payload, array[
          ''mint_request_id''
        ])
        and semantic_private.worker_json_field_is_valid_v03(payload, ''mint_request_id'', ''uuid'')
        and queue_user_id is null;
    else
      return false;');
    execute body;
  end if;
end;
$$;

-- Assertions: the validator answers both ways, the door widened, nothing
-- minted without a decision.
do $$
declare
  n integer;
begin
  if not semantic_private.worker_job_payload_is_valid_v03(
       'process_mint_requests', null,
       jsonb_build_object('mint_request_id', gen_random_uuid())) then
    raise exception '0258: the validator refuses a well-formed mint job';
  end if;
  if semantic_private.worker_job_payload_is_valid_v03(
       'process_mint_requests', null, '{}'::jsonb) then
    raise exception '0258: the validator accepts an empty mint payload';
  end if;

  select count(*) into n from semantic_private.observation_mappings
   where mapping_method = 'user_confirmed_qwen_mint';
  if n > 0 then
    raise exception '0258: a confirmed mapping exists before any keep';
  end if;

  select count(*) into n from ontology.concepts
   where concept_key like '%:kept_%';
  if n > 0 then
    raise exception '0258: a kept concept exists before any request was processed';
  end if;
end;
$$;
