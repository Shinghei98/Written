-- 0228 — a strike reaches the assertion, and a second tap is not an error.
--
-- ## Two things, both found by reading rather than by failing
--
-- ### 1. `0227` could raise on a double tap
--
-- `strike_calibration_item` inserted into `user_term_suppressions` with no
-- `on conflict` clause, against a table carrying **two partial unique indexes** —
-- one on `(user_id, concept_id, user_facing_predicate) where active`, one on the
-- provisional equivalent. So striking the same term twice raised, and so did
-- striking a term `apply_feedback` had already suppressed from the event.
--
-- The overlay's own `SUPPRESS` statement has always carried
-- `on conflict … do nothing`, with the reason written beside it: *a person
-- tapping twice is not a conflict.* The API had to say the same and did not.
-- Untargeted `do nothing` here, because either index may be the one hit
-- depending on whether the candidate is a concept or a provisional.
--
-- **Two writers is deliberate, not an oversight.** The API writes the
-- suppression so the consequence is immediate, and `apply_feedback` derives it
-- from the event so a strike recorded while the overlay was off is not lost.
-- Both are idempotent; neither depends on the other having run.
--
-- ### 2. The scorer never consulted suppressions
--
-- **Candidate selection already did.** `BUILD_REVIEW` has excluded suppressed
-- candidates since the overlay was written, `WITHDRAW` withdraws the struck
-- candidate, and `SUPPRESS` creates the row. What did not consult it was
-- **assertion creation** — so a term the person struck could still be asserted
-- about them by the next run, through the legacy scoring path that knows
-- nothing about the overlay.
--
-- (An earlier note in this project said nothing read `user_term_suppressions`.
-- That was a scan of `pg_proc` — database functions — generalised wrongly: the
-- worker reads it in Python, in `overlay.py`. The table was never unread; the
-- *scorer* was the gap.)
--
-- Scorer `0.17.0` consults it in two places, and the second is the one that
-- matters:
--
--   * `assert_travel`, which writes outside the concept loop and was the one
--     route by which a struck term could still be newly asserted;
--   * the concept loop, gated where **both `state` and `predicate` are known** —
--     which reaches the `update` as well as the `insert`. A term struck *after*
--     it was asserted is the case that matters most, and gating only the insert
--     would have left it standing forever.
--
-- The state written is **`candidate`**, not absence: the concept is still
-- scored and still evidence. It is the same withholding shape as
-- `policy_withheld` from `0222` and deliberately a *different kind* of refusal —
-- **personal, not global**. A strike says the term is wrong about this person
-- and says nothing about anybody else, which is why it lives in the scorer's
-- per-user pass and not in the ontology where `explicit_only` lives.
--
-- ## What this still does not do
--
-- Provisional-to-canonical merging and the legacy `BanList` path do not consult
-- suppressions. `calibration_reads` stays **off**, and the memo's condition for
-- turning it on — that review-item construction, assertion creation, merging and
-- the legacy paths all honour active suppressions — is now met for the first two
-- of four.

begin;

-- ---------------------------------------------------------------------------
-- 1. A second tap is not an error.
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

  -- **The event is appended every time.** Two taps are two facts about what the
  -- person did, and `review_events` is append-only precisely so the record of
  -- an action is never collapsed into the state it produced.
  insert into semantic_private.review_events
    (user_id, review_item_id, exposure_id, action, reason, model_revision, route_version)
  select me, item,
         (select x.id from semantic_private.review_exposures x
           where x.review_item_id = item and x.user_id = me
           order by x.displayed_at desc limit 1),
         'strike_off', 'ambiguous_rejection',
         row_item.model_revision, row_item.primary_route_id;

  -- **The suppression is a state, and states are idempotent.** Untargeted
  -- `do nothing`: which of the two partial unique indexes applies depends on
  -- whether this candidate is a concept or a provisional, and naming one would
  -- leave the other raising.
  insert into semantic_private.user_term_suppressions
    (user_id, concept_id, provisional_entity_id, user_facing_predicate,
     active, source_review_item_id, source_review_epoch)
  values (me, row_item.concept_id, row_item.provisional_entity_id,
          row_item.user_facing_predicate, true, item, row_item.review_epoch)
  on conflict do nothing;
end;
$$;

revoke all on function api.strike_calibration_item(uuid) from public, anon;
grant execute on function api.strike_calibration_item(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Scorer 0.17.0.
-- ---------------------------------------------------------------------------

insert into ontology.model_versions (id, model_key, version, model_role, code_hash, parameters, status)
select extensions.gen_random_uuid(), 'evidence_weighted_scorer', '0.17.0', 'scorer', null,
       old.parameters || jsonb_build_object(
         'user_suppression_withholding',
         'An assertion is not created, and an existing one is demoted to '
         || 'candidate, where semantic_private.user_term_suppressions holds an '
         || 'active row for that (user, concept, predicate). Applied in the '
         || 'concept loop where state and predicate are both known so it reaches '
         || 'the update as well as the insert — a term struck after it was '
         || 'asserted is the case that matters — and in assert_travel, which '
         || 'writes outside that loop and was otherwise the one route by which a '
         || 'struck term could still be newly asserted. Counted as '
         || 'user_suppressed. The state is candidate rather than absence: the '
         || 'concept is still scored and still evidence. This is a personal '
         || 'refusal and not a global one — it says the term is wrong about this '
         || 'person and nothing about anybody else, which is why it is here and '
         || 'not in the ontology where explicit_only lives. Candidate selection '
         || 'already honoured suppressions via the overlay''s BUILD_REVIEW; '
         || 'assertion creation was the gap.'
       ),
       'active'
  from (
    select * from ontology.model_versions
     where model_key = 'evidence_weighted_scorer'
     order by string_to_array(version, '.')::integer[] desc
     limit 1
  ) old
on conflict (model_key, version) do update
   set parameters = ontology.model_versions.parameters || excluded.parameters,
       status = 'active';

update ontology.model_versions set status = 'retired'
 where model_key = 'evidence_weighted_scorer'
   and status = 'active'
   and version <> '0.17.0';

-- ---------------------------------------------------------------------------
-- 3. Prove it.
-- ---------------------------------------------------------------------------

do $$
declare
  actives   integer;
  enqueued  integer;
  flag_on   boolean;
begin
  select count(*) into actives
    from ontology.model_versions
   where model_key = 'evidence_weighted_scorer' and status = 'active';
  if actives <> 1 then
    raise exception '0228: expected one active scorer, found %', actives;
  end if;

  -- **The insert is idempotent now**, asserted against the function body rather
  -- than promised. The bug was the absence of exactly this clause.
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'api' and p.proname = 'strike_calibration_item'
       and p.prosrc like '%user_term_suppressions%'
       and p.prosrc like '%on conflict do nothing%') then
    raise exception '0228: strike_calibration_item can still raise on a second tap';
  end if;

  -- **The surface stays dark**, and this migration is not the one that opens it.
  select enabled into flag_on
    from semantic_private.feature_flags where flag_key = 'calibration_reads';
  if coalesce(flag_on, false) then
    raise exception '0228: calibration_reads is enabled before suppression enforcement is complete';
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           'scorer 0.17.0: a struck term is not asserted about the person who struck it'
         ) into enqueued;

  raise notice '0228: strike is idempotent, scorer 0.17.0 active, calibration still off, % job(s) enqueued',
    enqueued;
end;
$$;

commit;
