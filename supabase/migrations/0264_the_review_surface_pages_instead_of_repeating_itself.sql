-- 0264 — the review surface pages instead of repeating itself.
--
-- Measured on the first real account to accumulate a backlog: 847 review
-- items in epoch 0, ranks collapsed to 0 (the builder numbered within each
-- pass — fixed worker-side in the same release as this), and
-- `api.begin_calibration` limiting BEFORE excluding already-exposed rows —
-- so the same arbitrary eight music suggestions came back on every open,
-- forever, while 839 items (every YouTube discovery among them) were
-- structurally unreachable. The epoch could never close either: the armer
-- hardcodes `review_epoch: 0`, and `finish_calibration` finishes only
-- exposed items, which is correct (keep-by-silence must never cover a row
-- nobody saw) and means an epoch with unexposed items stays open — which is
-- also correct, once paging works, because open is what lets the rest be
-- served.
--
-- Three changes, all server-side:
--   1. `current_review_epoch(user)` — the one definition of "which epoch is
--      being reviewed": the lowest with any unfinished item, else one past
--      the highest, else 0.
--   2. `begin_calibration` — deterministic order (rank, id); the exposure
--      batch excludes already-exposed rows BEFORE the limit; a new batch is
--      handed out only when nothing already exposed is still pending; and
--      finished items leave the answer — they are history, not questions.
--   3. The armer's `build_review_items` stage uses `current_review_epoch`
--      instead of the literal 0 — patched by regexp against
--      `pg_get_functiondef`, 0247's pattern, asserted both ways.

-- ---------------------------------------------------------------------------
-- 1. The epoch, defined once.
-- ---------------------------------------------------------------------------

create or replace function semantic_private.current_review_epoch(p_user uuid)
returns integer
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce(
    (select min(ri.review_epoch)
       from semantic_private.review_items ri
      where ri.user_id = p_user
        and not exists (
          select 1 from semantic_private.review_events e
           where e.review_item_id = ri.id and e.user_id = p_user
             and e.action = 'finish_review')),
    (select max(ri.review_epoch) + 1
       from semantic_private.review_items ri
      where ri.user_id = p_user),
    0)
$$;

revoke all on function semantic_private.current_review_epoch(uuid)
  from public, anon, authenticated, semantic_ingestor;
grant execute on function semantic_private.current_review_epoch(uuid)
  to semantic_worker;

-- ---------------------------------------------------------------------------
-- 2. begin_calibration, re-issued.
-- ---------------------------------------------------------------------------

create or replace function api.begin_calibration(batch_size integer default 8)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  me      uuid := (select auth.uid());
  epoch   integer;
  pending integer;
  result  jsonb;
begin
  if me is null then
    raise exception 'not signed in' using errcode = 'insufficient_privilege';
  end if;
  perform semantic_private.assert_surface_allowed('calibration');
  if batch_size is null or batch_size < 1 or batch_size > 25 then
    raise exception 'batch_size must be between 1 and 25';
  end if;

  -- **Resume before starting** — the same rule as before, now stated once.
  select semantic_private.current_review_epoch(me) into epoch;
  if not exists (select 1 from semantic_private.review_items ri
                  where ri.user_id = me and ri.review_epoch = epoch) then
    return jsonb_build_object('epoch', null, 'items', '[]'::jsonb);
  end if;

  -- **A new batch only when the current one is answered.** An exposed item is
  -- pending until it carries a decisive event (keep, confirm, edit,
  -- strike_off, finish_review) that no later restore has reopened. Without
  -- this gate every open of the page would hand out eight more rows whether
  -- or not the last eight were ever judged.
  select count(*) into pending
    from semantic_private.review_items ri
   where ri.user_id = me and ri.review_epoch = epoch
     and exists (select 1 from semantic_private.review_exposures x
                  where x.review_item_id = ri.id and x.user_id = me)
     and not exists (
       select 1 from semantic_private.review_events e
        where e.review_item_id = ri.id and e.user_id = me
          and e.action in ('keep', 'confirm', 'edit', 'strike_off', 'finish_review')
          and not exists (
            select 1 from semantic_private.review_events r2
             where r2.review_item_id = ri.id and r2.user_id = me
               and r2.action = 'restore' and r2.created_at > e.created_at));

  if pending = 0 then
    -- **Excluded before limited.** The old shape took the top eight by rank
    -- and THEN dropped the already-exposed — with deterministic order that is
    -- the same eight forever and the insert goes quiet. Exposure is recorded
    -- when the row is handed out, not when it is answered.
    insert into semantic_private.review_exposures
      (user_id, review_item_id, position, presentation_variant)
    select me, ri.id, ri.rank, 'calibration_v1'
      from semantic_private.review_items ri
     where ri.user_id = me and ri.review_epoch = epoch
       and not exists (
         select 1 from semantic_private.review_exposures x
          where x.review_item_id = ri.id and x.user_id = me)
     order by ri.rank, ri.id
     limit batch_size;
  end if;

  -- **Finished items leave the answer.** They are recorded history —
  -- keep-by-silence or an explicit decision — and re-serving them makes the
  -- card an archive instead of a queue.
  select jsonb_build_object(
    'epoch', epoch,
    'items', coalesce(jsonb_agg(jsonb_build_object(
        'review_item_id', ri.id,
        'concept_id', utc.concept_id,
        'provisional_entity_id', utc.provisional_entity_id,
        'label', coalesce(cr.preferred_label, pe.canonical_label),
        'predicate', utc.user_facing_predicate,
        'confidence_tier', ri.confidence_tier,
        'rank', ri.rank,
        -- The client draws the strike state; it never decides it.
        'struck', exists (
          select 1 from semantic_private.review_events e
           where e.review_item_id = ri.id and e.user_id = me
             and e.action = 'strike_off'
             and not exists (
               select 1 from semantic_private.review_events r2
                where r2.review_item_id = ri.id and r2.user_id = me
                  and r2.action = 'restore' and r2.created_at > e.created_at)))
      order by ri.rank, ri.id), '[]'::jsonb))
    into result
    from semantic_private.review_items ri
    join semantic_private.user_term_candidates utc
      on utc.id = ri.candidate_id and utc.user_id = ri.user_id
    left join ontology.concept_revisions cr
      on cr.concept_id = utc.concept_id
     and cr.ontology_version_id = (select id from ontology.versions where status = 'published')
    left join semantic_private.provisional_entities pe
      on pe.id = utc.provisional_entity_id
   where ri.user_id = me and ri.review_epoch = epoch
     and exists (select 1 from semantic_private.review_exposures x
                  where x.review_item_id = ri.id and x.user_id = me)
     and not exists (
       select 1 from semantic_private.review_events f
        where f.review_item_id = ri.id and f.user_id = me
          and f.action = 'finish_review');

  return result;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 3. The armer's build_review_items stage follows the epoch.
-- ---------------------------------------------------------------------------

do $$
declare
  body text;
  patched text;
begin
  body := pg_get_functiondef(
    'semantic_private.arm_candidate_overlay(uuid, text)'::regprocedure);

  if position('current_review_epoch' in body) > 0 then
    raise notice '0264: arm_candidate_overlay already follows the epoch';
    return;
  end if;

  -- The work test: a candidate not yet on the CURRENT epoch's page.
  patched := replace(body,
    'where i.candidate_id = c.id and i.review_epoch = 0',
    'where i.candidate_id = c.id and i.review_epoch = semantic_private.current_review_epoch(u.id)');
  if patched = body then
    raise exception '0264: the work-test literal was not found; the armer has drifted';
  end if;

  -- The payload: the epoch the job should build. The static 0 in plan.extra
  -- is overridden at insert time, because the VALUES list cannot see the user.
  body := patched;
  patched := replace(body,
    'plan.extra || jsonb_build_object(''user_id'', candidate.user_id::text)',
    'plan.extra || jsonb_build_object(''user_id'', candidate.user_id::text) '
    || '|| case when plan.job_type = ''build_review_items'' '
    || 'then jsonb_build_object(''review_epoch'', semantic_private.current_review_epoch(candidate.user_id)) '
    || 'else ''{}''::jsonb end');
  if patched = body then
    raise exception '0264: the payload expression was not found; the armer has drifted';
  end if;

  execute patched;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Both ways, on what can be asked without a signed-in session.
-- ---------------------------------------------------------------------------

do $$
declare
  body text;
begin
  -- The armer now consults the epoch in both places.
  body := pg_get_functiondef(
    'semantic_private.arm_candidate_overlay(uuid, text)'::regprocedure);
  if (length(body) - length(replace(body, 'current_review_epoch', '')))
       / length('current_review_epoch') <> 2 then
    raise exception '0264: expected exactly 2 epoch consultations in the armer';
  end if;

  -- The epoch helper answers 0 for an account with no review items — the
  -- same answer on an empty replay database and for a brand-new user.
  if semantic_private.current_review_epoch(
       '00000000-0000-4000-8000-000000000000'::uuid) <> 0 then
    raise exception '0264: a blank account must start at epoch 0';
  end if;

  -- begin_calibration orders deterministically and no longer re-serves
  -- finished items; the exposure insert excludes before it limits.
  body := pg_get_functiondef('api.begin_calibration(integer)'::regprocedure);
  if position('order by ri.rank, ri.id' in body) = 0 then
    raise exception '0264: begin_calibration lost its deterministic order';
  end if;
  if position('finish_review' in body) = 0 then
    raise exception '0264: begin_calibration no longer excludes finished items';
  end if;
end;
$$;
