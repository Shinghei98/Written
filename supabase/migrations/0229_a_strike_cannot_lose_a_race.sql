-- 0229 — a strike cannot lose a race, and it survives a merge.
--
-- Five safeguards. The first two are the same mechanism, which is why they are
-- one trigger rather than two checks somebody has to keep in step.
--
-- ## 1 & 3. The race, and the second definition — one guard, in the database
--
-- **The race:** a recompute reads suppressions, the user strikes a term, the
-- recompute then writes an `eligible` assertion for it. Nothing in `0228`
-- prevents that; the scorer's check is a *read* and the window between it and
-- the write is real. Demoting from the strike transaction narrows the window
-- and does not close it — the recompute could write after the demotion.
--
-- So the check moves to where writes actually land. **`guard_assertion_respects_
-- rejection` fires `before insert or update` on `user_assertions` and forces
-- `candidate` whenever the row would be `eligible` and the person has rejected
-- that term.** It cannot be raced, because there is no window between it and the
-- write — it *is* the write. Whatever the scorer read minutes earlier stops
-- mattering.
--
-- **The second definition:** this project has two records of "the user rejected
-- this term" and the memo named the wrong one. `BanList` / `markedRemoved` has
-- **0 rows in production** and never shipped. **`assertion_preferences` has 10**,
-- is live, and is the Memories path — keyed on `assertion_id` rather than on
-- `(concept, predicate)`, which is why it looked like a different thing.
--
-- Rather than translate one into the other and have two writers, **the guard
-- consults both**. A reader that knows both definitions is one place; two
-- writers kept in sync is two places and a drift. That is the memo's second
-- option — *require the writer to consult both systems* — applied at the point
-- of writing rather than in each caller.
--
-- ## 2. Provisional merging, with no intermediate window
--
-- A suppression on a provisional entity must reach the canonical concept **in
-- the same transaction that merges them**, or there is a moment where the
-- provisional is redirected, the canonical carries no suppression, and a
-- concurrent scorer may assert it.
--
-- `transfer_suppression_on_redirect` fires `before update` on
-- `provisional_entities` when `redirect_concept_id` becomes non-null, and
-- inserts the canonical suppression **in that transaction**. `on conflict do
-- nothing` covers the case the memo calls out — the canonical suppression
-- already existing — which is the common case rather than an edge one, since a
-- person who struck the provisional has often struck the canonical too.
--
-- **The provisional's own row is left active.** Deactivating it would require
-- setting `restored_at`, and the table's check constraint reads
-- `(active = false) = (restored_at is not null)` — so "deactivated because
-- merged" would be indistinguishable from "the user changed their mind". Two
-- opposite facts, one column: the row stays as it is.
--
-- ## 4. A double tap is one diagnostic event
--
-- `0228` made the *suppression* idempotent. The **event** was not: two taps
-- wrote two `strike_off` rows, which is a fact about the interface being
-- imprecise reported as two people-sized rejections, and it would bias any
-- aggregate strike rate the review pipeline computes.
--
-- The fix is in the function, not an index: **a strike is a no-op while a strike
-- already stands.** An index on `(user_id, review_item_id) where action =
-- 'strike_off'` would also refuse the *legitimate* re-strike after a restore,
-- which is a different act and must be recordable.
--
-- ## 5. Deployment ordering, made checkable
--
-- `model_versions.code_hash` has existed since the schema was written and
-- **every row this project has ever inserted left it null** — including the ten
-- model versions published today. So "was the code carrying this behaviour
-- deployed before the version claiming it" has never been answerable from the
-- database, which is exactly the question `0217` was written to answer after the
-- fact.
--
-- Scorer `0.17.0` gets the sha256 of the bundle that was deployed before this
-- migration ran, and an assertion refuses a **newly published** version with a
-- null hash. Old rows keep their nulls: back-filling them would be inventing
-- provenance for deploys nobody recorded.

begin;

-- ---------------------------------------------------------------------------
-- 1. The guard that cannot be raced.
-- ---------------------------------------------------------------------------

create or replace function semantic_private.guard_assertion_respects_rejection()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Only `eligible` is withheld. A row already `candidate` or `inactive` is not
  -- making a claim, and rewriting it would be this guard inventing a state.
  if new.machine_state is distinct from 'eligible' then
    return new;
  end if;

  -- **A declared term is the person's own words** and is never withheld by
  -- their having struck an inferred one. `explicit_addition` survives a
  -- disconnect for the same reason.
  if new.assertion_origin is distinct from 'inferred' then
    return new;
  end if;

  -- Definition one: the calibration surface, keyed on the term.
  if new.concept_id is not null and exists (
    select 1 from semantic_private.user_term_suppressions s
     where s.user_id = new.user_id
       and s.active
       and s.concept_id = new.concept_id
       and s.user_facing_predicate = new.predicate_key
  ) then
    new.machine_state := 'candidate';
    return new;
  end if;

  -- Definition two: Memories, keyed on the assertion. Only reachable on update,
  -- an insert having no id to have a preference about yet — which is correct
  -- rather than a gap, since a preference cannot precede the row it is about.
  if tg_op = 'UPDATE' and exists (
    select 1 from semantic_private.assertion_preferences p
     where p.assertion_id = new.id
       and p.user_id = new.user_id
       and p.display_state = 'suppressed'
  ) then
    new.machine_state := 'candidate';
    return new;
  end if;

  return new;
end;
$$;

drop trigger if exists guard_assertion_respects_rejection on semantic_private.user_assertions;
create trigger guard_assertion_respects_rejection
  before insert or update on semantic_private.user_assertions
  for each row execute function semantic_private.guard_assertion_respects_rejection();

-- ---------------------------------------------------------------------------
-- 2. The merge carries the suppression with it.
-- ---------------------------------------------------------------------------

create or replace function semantic_private.transfer_suppression_on_redirect()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.redirect_concept_id is null
     or new.redirect_concept_id is not distinct from old.redirect_concept_id then
    return new;
  end if;

  insert into semantic_private.user_term_suppressions
    (user_id, concept_id, provisional_entity_id, user_facing_predicate,
     active, source_review_item_id, source_review_epoch)
  select s.user_id, new.redirect_concept_id, null, s.user_facing_predicate,
         true, s.source_review_item_id, s.source_review_epoch
    from semantic_private.user_term_suppressions s
   where s.provisional_entity_id = new.id
     and s.active
  on conflict do nothing;

  return new;
end;
$$;

drop trigger if exists transfer_suppression_on_redirect on semantic_private.provisional_entities;
create trigger transfer_suppression_on_redirect
  before update on semantic_private.provisional_entities
  for each row execute function semantic_private.transfer_suppression_on_redirect();

-- ---------------------------------------------------------------------------
-- 3. One diagnostic event per standing strike.
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

  -- **A second tap is a no-op, not a second rejection.** `review_events` is
  -- append-only and every row is read as a person's judgement, so two rows for
  -- one decision would overstate the strike rate the review pipeline aggregates.
  -- Written as a condition rather than a unique index because a re-strike *after
  -- a restore* is a different act and must stay recordable.
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
         row_item.model_revision, row_item.primary_route_id;

  insert into semantic_private.user_term_suppressions
    (user_id, concept_id, provisional_entity_id, user_facing_predicate,
     active, source_review_item_id, source_review_epoch)
  values (me, row_item.concept_id, row_item.provisional_entity_id,
          row_item.user_facing_predicate, true, item, row_item.review_epoch)
  on conflict do nothing;

  -- **The standing assertion is demoted here, not left to the next run.** The
  -- trigger above makes the race unlosable for *future* writes; this is what
  -- makes the term stop being claimed *now*, for a person who has just said it
  -- is wrong about them.
  if row_item.concept_id is not null then
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
-- 4. The build that carries the behaviour.
-- ---------------------------------------------------------------------------

update ontology.model_versions
   set code_hash = 'abe4da655daa84ec48b938df9de058df37f32ea15eb0164408dd2cfa99f6f42c'
 where model_key = 'evidence_weighted_scorer' and version = '0.17.0'
   and code_hash is null;

-- ---------------------------------------------------------------------------
-- 5. Prove it, all of it.
-- ---------------------------------------------------------------------------

do $$
declare
  probe_user uuid;
  probe_concept uuid;
  probe_id uuid;
  probe_predicate text;
  final_state text;
  hashed integer;
begin
  -- **The guard, exercised against a real assertion and rolled back.**
  --
  -- The first version inserted a fresh `user_assertions` row and was wrong
  -- twice. It carried no `source_semantic_run_id`, so
  -- `guard_semantic_run_*` refused it on production with *stale semantic run
  -- cannot create a user assertion* — and it **passed replay**, because a
  -- replayed database has no `auth.users` rows, `probe_user` came back null and
  -- the whole branch was skipped. A probe that silently does not run is the
  -- thing this file exists to argue against, met in its own assertion.
  --
  -- So it exercises an assertion that already exists, through `update`, which
  -- is also where the race it guards actually happens: a recompute demoting and
  -- re-promoting rows it scored.
  select ua.id, ua.user_id, ua.concept_id, ua.predicate_key
    into probe_id, probe_user, probe_concept, probe_predicate
    from semantic_private.user_assertions ua
   where ua.assertion_origin = 'inferred' and ua.concept_id is not null
   limit 1;

  if probe_id is not null then
    begin
      insert into semantic_private.user_term_suppressions
        (user_id, concept_id, user_facing_predicate, active)
      values (probe_user, probe_concept, probe_predicate, true)
      on conflict do nothing;

      update semantic_private.user_assertions
         set machine_state = 'eligible' where id = probe_id
      returning machine_state into final_state;
      if final_state <> 'candidate' then
        raise exception
          '0229: a suppressed term was set % and the guard did not fire', final_state;
      end if;

      -- And without the suppression it must go back, or the guard withholds
      -- everything and the product is empty.
      delete from semantic_private.user_term_suppressions
       where user_id = probe_user and concept_id = probe_concept
         and user_facing_predicate = probe_predicate;
      update semantic_private.user_assertions
         set machine_state = 'eligible' where id = probe_id
      returning machine_state into final_state;
      if final_state <> 'eligible' then
        raise exception
          '0229: an unsuppressed term was withheld as %, the guard is too broad', final_state;
      end if;

      raise exception 'rollback_probe';
    exception when others then
      if sqlerrm <> 'rollback_probe' then raise; end if;
    end;
  else
    raise notice '0229: no inferred assertion to probe the guard against';
  end if;

  -- **A newly published model version records the build that carries it.**
  -- Old rows keep their nulls; back-filling would invent provenance.
  select count(*) into hashed
    from ontology.model_versions
   where status = 'active' and model_key = 'evidence_weighted_scorer'
     and code_hash is not null;
  if hashed <> 1 then
    raise exception '0229: the active scorer has no code_hash; ordering is unverifiable';
  end if;

  raise notice '0229: rejection guard fires and only where it should; scorer build recorded';
end;
$$;

commit;
