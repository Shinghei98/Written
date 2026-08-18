-- 0231 — a strike that could never have run.
--
-- ## What `0230` shipped
--
-- `0230` closed a real gap: the calibration strike wrote `user_term_suppressions`
-- and `list_assertions` reads `user_suppressions`, so a struck term that later
-- became an assertion would still be drawn on somebody's Memories page. The
-- remedy — one strike, both records, one transaction — is right and stands.
--
-- The insert it added cannot execute:
--
--     insert into semantic_private.user_suppressions
--       (user_id, concept_id, predicate_key, surface, active)
--
-- `semantic_private.user_suppressions.source_feedback_event_id` has been
-- `not null` with no default since `0042`, and no migration alters it. Every
-- concept-backed strike raises `23502`. Because the insert sits inside one
-- function body, the review event, the `user_term_suppressions` row and the
-- assertion demotion roll back with it: **the strike does not half-apply, it
-- fails entirely.**
--
-- ## Why nothing noticed
--
-- `calibration_reads` is `false`, so no caller has reached it — it would have
-- failed on the day the flag was turned on, which is the worst day to find it.
--
-- And `0230` proved itself by reading its own source. Its check greps
-- `pg_get_functiondef` for `%user_suppressions%` and `%'memories'%` and asserts
-- both appear. They do. A check on a function's source text is not a check on
-- its behaviour — this project already had that sentence, about
-- `assert_surface_allowed`, and the same lesson arrived here from the other end:
-- there the worry was a guard folded away at plan time, here a statement that
-- parses and cannot run.
--
-- So this migration does not add another source-text assertion. The behavioural
-- proof is `supabase/tests/0230_calibration_lifecycle_contract.sql`, which calls
-- `api.strike_calibration_item` against seeded rows with `calibration_reads`
-- flipped inside its own transaction, and which `tools/replay_contracts.sh` now
-- runs on every replay. That file existed, uncommitted and unrun, while the
-- defect it was written to catch sat in the applied chain.
--
-- ## What changes
--
-- The strike captures the id of the `review_events` row it has just written and
-- passes it as `source_feedback_event_id`. That is the column's meaning —
-- *which feedback caused this suppression* — so the repair is to supply the fact
-- rather than to relax the constraint. The event is written first in the same
-- function, so the value is already in hand; nothing new is looked up.
--
-- `restore_calibration_item` fills `lifted_by_feedback_event_id` for the same
-- reason. It is nullable, so leaving it empty raised nothing and lost the other
-- half of the record: which act lifted the suppression. A strike that names its
-- cause and a restore that does not would be an audit trail with one end.
--
-- **`user_term_suppressions` is untouched.** Its insert already names
-- `source_review_item_id` and `source_review_epoch` and has always been able to
-- run. The two tables answer two questions — *may this be reviewed again* and
-- *may this be shown as a claim* — and `0230`'s reasoning for writing both is
-- unchanged.
--
-- The `on conflict do nothing` stays and still arbitrates
-- `one_active_concept_suppression`, so a double tap remains one suppression and
-- a strike after a restore correctly writes a new one.
--
-- ## The neighbouring hazard, checked rather than assumed
--
-- `user_suppressions.predicate_key` carries a foreign key to
-- `ontology.relation_types(predicate_key)`; `user_term_suppressions.user_facing_predicate`
-- carries none. So the two records accept different vocabularies, and a
-- calibration predicate outside `relation_types` would fail on this side only —
-- the same shape as `0050`'s `key_version`, two columns that must accept the same
-- words accepting different ones.
--
-- All three predicates the scorer can write today — `affinity_to`,
-- `participates_in_activity`, `follows_activity` — resolve. The assertion at the
-- foot states it as a property of whatever candidates exist, so it answers on an
-- empty database and on production, and a fourth predicate minted without a
-- relation type fails the next replay rather than the next strike.

-- ---------------------------------------------------------------------------
-- 1. The strike names the event that caused it.
-- ---------------------------------------------------------------------------

create or replace function api.strike_calibration_item(item uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me       uuid := (select auth.uid());
  row_item record;
  event_id uuid;
begin
  if me is null then
    raise exception 'not signed in' using errcode = 'insufficient_privilege';
  end if;
  perform semantic_private.assert_surface_allowed('calibration');

  select ri.id, ri.review_epoch, ri.model_revision, ri.primary_route_id,
         utc.concept_id, utc.provisional_entity_id, utc.user_facing_predicate
    into row_item
    from semantic_private.review_items ri
    join semantic_private.user_term_candidates utc
      on utc.id = ri.candidate_id and utc.user_id = ri.user_id
   where ri.id = item and ri.user_id = me;
  if row_item.id is null then
    raise exception 'no such review item';
  end if;

  if not exists (select 1 from semantic_private.review_exposures x
                  where x.review_item_id = item and x.user_id = me) then
    raise exception 'that item has not been shown';
  end if;

  -- A second tap is a no-op, not a second rejection. A re-strike after a
  -- restore is a different act and stays recordable.
  if exists (
    select 1 from semantic_private.review_events e
     where e.review_item_id = item and e.user_id = me and e.action = 'strike_off'
       and not exists (
         select 1 from semantic_private.review_events r
          where r.review_item_id = item and r.user_id = me
            and r.action = 'restore' and r.created_at > e.created_at)
  ) then
    return;
  end if;

  insert into semantic_private.review_events
    (user_id, review_item_id, exposure_id, action, reason, model_revision, route_version)
  select me, item,
         (select x.id from semantic_private.review_exposures x
           where x.review_item_id = item and x.user_id = me
           order by x.displayed_at desc limit 1),
         'strike_off', 'ambiguous_rejection',
         row_item.model_revision, row_item.primary_route_id
  returning id into event_id;

  -- What the overlay reads: may this be reviewed again.
  insert into semantic_private.user_term_suppressions
    (user_id, concept_id, provisional_entity_id, user_facing_predicate,
     active, source_review_item_id, source_review_epoch)
  values (me, row_item.concept_id, row_item.provisional_entity_id,
          row_item.user_facing_predicate, true, item, row_item.review_epoch)
  on conflict do nothing;

  -- **What `list_assertions` reads: may this be shown as a claim.** Without
  -- this, a struck term that later became an assertion would still be drawn on
  -- the person's Memories page — `list_assertions` admits `candidate` as well as
  -- `eligible`, so the guard alone does not hide it.
  --
  -- `source_feedback_event_id` is the strike event written immediately above.
  -- It is `not null` and has no default; naming it is what makes this statement
  -- executable, and what makes the row say why it exists.
  if row_item.concept_id is not null then
    insert into semantic_private.user_suppressions
      (user_id, concept_id, predicate_key, surface, active, source_feedback_event_id)
    values (me, row_item.concept_id, row_item.user_facing_predicate, 'memories',
            true, event_id)
    on conflict do nothing;

    update semantic_private.user_assertions
       set machine_state = 'candidate', updated_at = now()
     where user_id = me
       and concept_id = row_item.concept_id
       and predicate_key = row_item.user_facing_predicate
       and assertion_origin = 'inferred'
       and machine_state = 'eligible';
  end if;
end;
$$;

revoke all on function api.strike_calibration_item(uuid) from public, anon;
grant execute on function api.strike_calibration_item(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. The restore names the event that lifted it.
-- ---------------------------------------------------------------------------

create or replace function api.restore_calibration_item(item uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me       uuid := (select auth.uid());
  row_item record;
  event_id uuid;
begin
  if me is null then
    raise exception 'not signed in' using errcode = 'insufficient_privilege';
  end if;
  perform semantic_private.assert_surface_allowed('calibration');

  select ri.id, ri.model_revision, ri.primary_route_id,
         utc.concept_id, utc.user_facing_predicate
    into row_item
    from semantic_private.review_items ri
    join semantic_private.user_term_candidates utc
      on utc.id = ri.candidate_id and utc.user_id = ri.user_id
   where ri.id = item and ri.user_id = me;
  if row_item.id is null then
    raise exception 'no such review item';
  end if;

  insert into semantic_private.review_events
    (user_id, review_item_id, exposure_id, action, reason, model_revision, route_version)
  select me, item,
         (select x.id from semantic_private.review_exposures x
           where x.review_item_id = item and x.user_id = me
           order by x.displayed_at desc limit 1),
         'restore', 'correct', row_item.model_revision, row_item.primary_route_id
  returning id into event_id;

  update semantic_private.user_term_suppressions
     set active = false, restored_at = now()
   where user_id = me and source_review_item_id = item and active;

  if row_item.concept_id is not null then
    update semantic_private.user_suppressions
       set active = false, lifted_at = now(),
           lifted_by_feedback_event_id = event_id
     where user_id = me
       and concept_id = row_item.concept_id
       and predicate_key = row_item.user_facing_predicate
       and surface = 'memories'
       and active;
  end if;
end;
$$;

revoke all on function api.restore_calibration_item(uuid) from public, anon;
grant execute on function api.restore_calibration_item(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. What must stay true.
-- ---------------------------------------------------------------------------

do $$
declare
  nullable text;
  stray    text;
begin
  -- The reason this migration exists. If the column ever becomes nullable the
  -- repair above is still correct — a suppression should name its cause — but
  -- the next reader deserves to know the constraint moved rather than infer it.
  select c.is_nullable into nullable
    from information_schema.columns c
   where c.table_schema = 'semantic_private'
     and c.table_name = 'user_suppressions'
     and c.column_name = 'source_feedback_event_id';
  if nullable is null then
    raise exception '0231: semantic_private.user_suppressions.source_feedback_event_id is gone';
  end if;
  if nullable <> 'NO' then
    raise exception '0231: source_feedback_event_id is now nullable (%); 0230 failed because it was not', nullable;
  end if;

  -- Stated over the candidates that exist, so an empty database answers it and
  -- production answers it, and a predicate minted without a relation type fails
  -- here rather than at somebody's strike.
  select string_agg(distinct c.user_facing_predicate, ', ') into stray
    from semantic_private.user_term_candidates c
   where not exists (select 1 from ontology.relation_types rt
                      where rt.predicate_key = c.user_facing_predicate);
  if stray is not null then
    raise exception '0231: candidate predicates absent from ontology.relation_types: %', stray;
  end if;
end;
$$;
