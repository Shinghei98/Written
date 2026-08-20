-- 0267 — a suppression names the event that actually exists.
--
-- Found by the owner striking a concept-backed suggestion: it kept coming
-- back. Every provisional-backed strike worked; every concept-backed one
-- failed. `strike_calibration_item` takes the `review_events` row it has just
-- written and passes its id as `user_suppressions.source_feedback_event_id`,
-- and that column's foreign key points at `semantic_private.feedback_events`
-- — a different table. So the value never resolves and the transaction dies.
--
-- ## The history, because this is the third pass over the same line
--
-- `0230` wrote the insert without the column at all (`23502`, not null).
-- `0231` diagnosed that correctly and supplied the review event's id,
-- reasoning that the column means *which feedback caused this suppression* —
-- which is right about the meaning and wrong about the table. It swapped a
-- not-null violation for a foreign-key one. `0233`'s redirect trigger copies
-- the same shape and carries the same defect, unfired only because no
-- provisional has been redirected yet.
--
-- ## Why the test that exists for exactly this did not catch it
--
-- `supabase/tests/0230_calibration_lifecycle_contract.sql` calls
-- `api.strike_calibration_item` against seeded rows, and passes. The foreign
-- key is `deferrable initially deferred`, so it is checked at COMMIT — and
-- the test ends in `rollback`, which is the right shape for a test and means
-- the constraint is never checked at all. `0231`'s own note says a check on a
-- function's source text is not a check on its behaviour; this is the next
-- turn of that screw. **A deferred constraint inside a rolled-back
-- transaction is not enforced, so a test that never commits cannot see one.**
-- The repair is `set constraints all immediate` after the act — which forces
-- every deferred check to fire while the transaction is still alive and still
-- rollable — and this migration adds it to that test.
--
-- ## What changes
--
-- A calibration strike is not assertion feedback: `feedback_events.assertion_id`
-- is `not null`, and a strike can happen before any assertion exists — which
-- is the whole point, since it must stop the term becoming a visible claim
-- later. So the suppression gets a second lineage column pointing at the
-- table the event is actually in, and a check that says exactly one of the two
-- is present. The meaning `0231` identified is kept; it now has somewhere true
-- to live.
--
-- All eight standing rows are genuine assertion feedback (verified against
-- both tables before this ran), so nothing is backfilled and nothing moves.

alter table semantic_private.user_suppressions
  alter column source_feedback_event_id drop not null;

alter table semantic_private.user_suppressions
  add column if not exists source_review_event_id uuid;

alter table semantic_private.user_suppressions
  add constraint user_suppressions_source_review_event_id_user_id_fkey
  foreign key (source_review_event_id, user_id)
  references semantic_private.review_events (id, user_id)
  deferrable initially deferred;

-- **Exactly one, never zero.** `0233`'s "fails closed on a suppression with
-- no strike behind it" is the standing rule and this keeps it: a row still
-- cannot exist without naming the act that caused it. It may now name either
-- kind of act.
alter table semantic_private.user_suppressions
  add constraint user_suppressions_has_one_source_check
  check (num_nonnulls(source_feedback_event_id, source_review_event_id) = 1);

-- **And the same for the lift.** `restore_calibration_item` writes
-- `lifted_by_feedback_event_id = event_id` with the id of the `review_events`
-- row it has just written — `0231` added that deliberately, so that "a strike
-- that names its cause and a restore that does not" would not be an audit
-- trail with one end, and it points at the same wrong table. It is nullable,
-- so it raised nothing and lost nothing until the deferred check was made to
-- fire; now it raises, which is how this one surfaced at all.
alter table semantic_private.user_suppressions
  add column if not exists lifted_by_review_event_id uuid;

alter table semantic_private.user_suppressions
  add constraint user_suppressions_lifted_by_review_event_id_user_id_fkey
  foreign key (lifted_by_review_event_id, user_id)
  references semantic_private.review_events (id, user_id)
  deferrable initially deferred;

comment on column semantic_private.user_suppressions.lifted_by_review_event_id is
  'The calibration restore that lifted this suppression (0267), beside '
  'lifted_by_feedback_event_id for the assertion surface. Unlike the source '
  'columns neither is required: a standing suppression has been lifted by '
  'nothing.';

comment on column semantic_private.user_suppressions.source_review_event_id is
  'The calibration strike that caused this suppression (0267). Its sibling '
  'source_feedback_event_id names an assertion-surface feedback event instead; '
  'exactly one of the two is present, because a suppression that cannot name '
  'the act behind it is not one to keep.';

-- ---------------------------------------------------------------------------
-- The two writers.
-- ---------------------------------------------------------------------------

create or replace function api.strike_calibration_item(item uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
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
  -- the person's Memories page — `list_assertions` admits `candidate` as well
  -- as `eligible`, so the guard alone does not hide it.
  --
  -- `source_review_event_id`, not `source_feedback_event_id`: the strike above
  -- is a `review_events` row, and the older column's foreign key points at
  -- `feedback_events`, which requires an assertion this strike may not have
  -- (0267).
  if row_item.concept_id is not null then
    insert into semantic_private.user_suppressions
      (user_id, concept_id, predicate_key, surface, active, source_review_event_id)
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
$function$;

-- `0233`'s redirect trigger carries the identical defect, unfired only
-- because no provisional has been redirected yet. Same repair, same column.
do $$
declare
  body text;
  patched text;
begin
  body := pg_get_functiondef(
    'semantic_private.transfer_suppression_on_redirect()'::regprocedure);
  patched := replace(body,
    E'     source_feedback_event_id)', E'     source_review_event_id)');
  if patched = body then
    raise exception '0267: the redirect trigger no longer names the column it used to';
  end if;
  execute patched;
end;
$$;

do $$
declare
  body text;
  patched text;
begin
  body := pg_get_functiondef('api.restore_calibration_item(uuid)'::regprocedure);
  patched := replace(body,
    'lifted_by_feedback_event_id = event_id',
    'lifted_by_review_event_id = event_id');
  if patched = body then
    raise exception '0267: the restore no longer writes the column it used to';
  end if;
  -- The reset in the same function clears whichever half is set, so it names
  -- both rather than assuming which one filled it.
  patched := replace(patched,
    'lifted_by_feedback_event_id = null',
    'lifted_by_feedback_event_id = null, lifted_by_review_event_id = null');
  execute patched;
end;
$$;

-- ---------------------------------------------------------------------------
-- Both ways, with the deferred checks forced to fire.
-- ---------------------------------------------------------------------------

do $$
declare
  ok boolean;
begin
  -- **The constraint exists, on an empty database and on a full one.** The
  -- first version of this block tried the insert against `auth.users` joined
  -- to a concept and declared success when it was refused — on a replay
  -- database both are empty, the select yielded no rows, nothing was refused
  -- and the assertion failed for the one reason it must not: absence of
  -- input. Assert the transformation, not the precondition.
  if not exists (
    select 1 from pg_constraint c
      join pg_class t on t.oid = c.conrelid
      join pg_namespace n on n.oid = t.relnamespace
     where n.nspname = 'semantic_private' and t.relname = 'user_suppressions'
       and c.conname = 'user_suppressions_has_one_source_check') then
    raise exception '0267: the one-source check is not on the table';
  end if;

  -- And it answers the same way about a row, whenever there is one to try.
  if exists (select 1 from auth.users)
     and exists (select 1 from ontology.concept_revisions) then
    begin
      insert into semantic_private.user_suppressions
        (user_id, concept_id, predicate_key, surface, active)
      select u.id, c.concept_id, 'affinity_to', 'memories', true
        from auth.users u, ontology.concept_revisions c limit 1;
      raise exception '0267: a suppression with no source was accepted';
    exception when check_violation then
      null;
    end;
  end if;

  -- **Both writers name the review-event column, and neither's executable
  -- text names the feedback one.** Comments are stripped before the search:
  -- the first version of this check failed against the comment two screens
  -- above explaining which column is *not* used, which is the same class of
  -- mistake as checking a guard by reading its source — a text search cannot
  -- tell code from prose unless it is told to.
  select position('source_review_event_id' in strip) > 0
     and position('source_feedback_event_id' in strip) = 0
    into ok
    from (select regexp_replace(
                   pg_get_functiondef('api.strike_calibration_item(uuid)'::regprocedure),
                   '--[^\n]*', '', 'g') as strip) t;
  if not ok then
    raise exception '0267: the strike still names the feedback column';
  end if;

  select position('source_review_event_id' in strip) > 0
     and position('source_feedback_event_id' in strip) = 0
    into ok
    from (select regexp_replace(
                   pg_get_functiondef(
                     'semantic_private.transfer_suppression_on_redirect()'::regprocedure),
                   '--[^\n]*', '', 'g') as strip) t;
  if not ok then
    raise exception '0267: the redirect trigger still names the feedback column';
  end if;
end;
$$;
