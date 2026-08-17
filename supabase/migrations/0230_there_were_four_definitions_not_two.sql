-- 0230 — there were four definitions, not two.
--
-- ## What reading `list_assertions` showed
--
-- `0229` added a branch to `guard_assertion_respects_rejection` that demoted an
-- assertion to `candidate` when `assertion_preferences.display_state` was
-- `suppressed`, on the reasoning that this project had **two** records of "the
-- user rejected this term" and one guard should read both.
--
-- It has **four**, and the branch was aimed at the wrong one:
--
-- | table | rows | honoured by `list_assertions` |
-- |---|---|---|
-- | `user_suppressions` (surface-scoped) | 8 | **yes** — `not exists (… surface = 'memories' and active)` |
-- | `assertion_preferences` | 10 | **yes** — `display_state <> 'suppressed'` |
-- | `user_term_suppressions` (calibration) | 0 | **no** |
-- | `BanList` / `markedRemoved` | 0 | never shipped |
--
-- Two things follow, and both make `0229`'s second branch wrong rather than
-- merely redundant.
--
-- **It changed nothing that was visible.** `list_assertions` admits
-- `machine_state in ('candidate', 'eligible')` — so demoting to `candidate` does
-- not hide a row. The preference filter beside it was already doing the hiding,
-- at read time, for every row rather than for whichever ones a recompute
-- happened to rewrite.
--
-- **And it destroyed something that was not.** `machine_state` is the scorer's
-- verdict about the evidence. `display_state` is a person's choice about their
-- own page. Writing the second into the first collapses two facts into one
-- column and loses the scorer's — which is precisely the distinction this
-- project already draws between `assertion_reviews` and `assertion_preferences`:
-- *a diagnostic judgement silently becoming a hide.*
--
-- It also applied unevenly, which is how it was noticed: three suppressed
-- assertions were demoted because a recompute rewrote them while the guard was
-- live, and two identical ones were not, because nothing rewrote those. A rule
-- whose effect depends on scheduling is not a rule.
--
-- So the branch is removed and the three rows are put back.
--
-- ## The gap that was actually there
--
-- The calibration strike writes `user_term_suppressions`, and **`list_assertions`
-- does not read that table.** So a term somebody struck in calibration, if it
-- later became an assertion, would still be drawn on their Memories page. The
-- guard keeps it from becoming `eligible`, and `candidate` is displayed too, so
-- the guard alone does not close it.
--
-- `strike_calibration_item` now also writes `user_suppressions` with
-- `surface = 'memories'` — the table the reader honours. One strike, both
-- records, in one transaction. That is the convergence the memo asked for,
-- against the definition that turns out to be load-bearing.
--
-- **`user_term_suppressions` is not replaced by it.** The overlay reads that one
-- — `BUILD_REVIEW` excludes suppressed candidates and `WITHDRAW` withdraws them
-- — and it is keyed on the *candidate's* predicate, which is the right key for
-- deciding what to review. They are two questions: *may this be reviewed again*
-- and *may this be shown as a claim*. Writing both is the honest answer; making
-- one a view over the other would force one key onto both questions.

begin;

-- ---------------------------------------------------------------------------
-- 1. The guard reads the term-level suppression and nothing else.
-- ---------------------------------------------------------------------------

create or replace function semantic_private.guard_assertion_respects_rejection()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.machine_state is distinct from 'eligible' then
    return new;
  end if;

  -- **A declared term is the person's own words** and is never withheld by
  -- their having struck an inferred one.
  if new.assertion_origin is distinct from 'inferred' then
    return new;
  end if;

  -- **One definition here, deliberately.** The surface-scoped
  -- `user_suppressions` and `assertion_preferences` are both read by
  -- `list_assertions` at query time, for every row, which is stronger than a
  -- write-time guard that only reaches rows something happens to rewrite. This
  -- guard exists for the one record no reader consults: the calibration strike.
  if new.concept_id is not null and exists (
    select 1 from semantic_private.user_term_suppressions s
     where s.user_id = new.user_id
       and s.active
       and s.concept_id = new.concept_id
       and s.user_facing_predicate = new.predicate_key
  ) then
    new.machine_state := 'candidate';
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Put back what the removed branch demoted.
-- ---------------------------------------------------------------------------
--
-- Restoring the scorer's verdict, not overriding it: these rows were `eligible`
-- because the scorer found them so, and the only thing that changed them was a
-- guard that should not have looked. **Only rows whose sole reason for being
-- `candidate` was that branch** — a preference of `suppressed`, no calibration
-- strike, and a current eligible score — are touched.

update semantic_private.user_assertions ua
   set machine_state = 'eligible', updated_at = now()
  from semantic_private.assertion_preferences p
 where p.assertion_id = ua.id
   and p.user_id = ua.user_id
   and p.display_state = 'suppressed'
   and ua.machine_state = 'candidate'
   and ua.assertion_origin = 'inferred'
   and ua.updated_at > now() - interval '6 hours'
   and not exists (
     select 1 from semantic_private.user_term_suppressions s
      where s.user_id = ua.user_id and s.active
        and s.concept_id = ua.concept_id
        and s.user_facing_predicate = ua.predicate_key);

-- ---------------------------------------------------------------------------
-- 3. A strike reaches the record the reader honours.
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
         row_item.model_revision, row_item.primary_route_id;

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
  if row_item.concept_id is not null then
    insert into semantic_private.user_suppressions
      (user_id, concept_id, predicate_key, surface, active)
    values (me, row_item.concept_id, row_item.user_facing_predicate, 'memories', true)
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

-- **Restoring lifts both**, or a restore would leave the term invisible on
-- Memories while the calibration surface showed it unstruck.
create or replace function api.restore_calibration_item(item uuid)
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
         'restore', 'correct', row_item.model_revision, row_item.primary_route_id;

  update semantic_private.user_term_suppressions
     set active = false, restored_at = now()
   where user_id = me and source_review_item_id = item and active;

  if row_item.concept_id is not null then
    update semantic_private.user_suppressions
       set active = false, lifted_at = now()
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
-- 4. Prove it.
-- ---------------------------------------------------------------------------

do $$
declare
  stranded integer;
begin
  -- **The guard no longer reads preferences**, asserted against the body. The
  -- whole point is that it stopped conflating a display choice with a verdict.
  --
  -- **Comments stripped before matching.** `prosrc` carries them, and the
  -- guard's own comment *names* `assertion_preferences` while explaining why it
  -- no longer reads it — so the first version of this check failed on the
  -- migration that fixed the thing it was checking for. Same shape as the
  -- reserved-verb scan in `0227` matching `api.confirm_assertion`: a source-text
  -- assertion that reads prose as code.
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'semantic_private'
       and p.proname = 'guard_assertion_respects_rejection'
       and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') like '%assertion_preferences%') then
    raise exception '0230: the guard still reads assertion_preferences';
  end if;

  -- **The strike writes the record the reader honours**, which is the gap that
  -- was actually there.
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'api' and p.proname = 'strike_calibration_item'
       and p.prosrc like '%user_suppressions%'
       and p.prosrc like '%''memories''%') then
    raise exception '0230: a strike still does not reach user_suppressions';
  end if;

  -- **Nothing is left demoted by the removed branch.** Conditional on there
  -- being such rows at all, so an empty database replays.
  select count(*) into stranded
    from semantic_private.user_assertions ua
    join semantic_private.assertion_preferences p
      on p.assertion_id = ua.id and p.user_id = ua.user_id
   where p.display_state = 'suppressed'
     and ua.machine_state = 'candidate'
     and ua.assertion_origin = 'inferred'
     and ua.updated_at > now() - interval '6 hours'
     and not exists (
       select 1 from semantic_private.user_term_suppressions s
        where s.user_id = ua.user_id and s.active
          and s.concept_id = ua.concept_id
          and s.user_facing_predicate = ua.predicate_key);
  if stranded <> 0 then
    raise exception '0230: % assertion(s) are still demoted by the removed branch', stranded;
  end if;

  raise notice '0230: guard reads one definition; strike reaches the reader''s';
end;
$$;

commit;
