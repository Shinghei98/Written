-- 0158 — scorer 0.11.0: a trip is asserted from the calendar's own reading.
--
-- **No guard is bypassed and none needed to be.** Calendar observations still
-- may not enter `observation_mappings`; the writer never tries. It asserts
-- `scheduled_travel_to` — the classifier's own predicate, in
-- `ontology.relation_types` all along — against the `travel:*` concepts `0157`
-- minted, and writes **no evidence rows at all**. Every calendar guard fires on
-- `assertion_evidence`, and there is nothing there to fire on.
--
-- That shape is the schema's own: `assertion_has_calendar_evidence` matches on
-- `predicate_key in ('recurring_presence_at', 'home_base_candidate')` with no
-- mapping join, so a calendar assertion has always been meant to be recognised
-- by its predicate rather than by its evidence.
--
-- **A score with no evidence, deliberately.** `list_assertions` withholds an
-- inferred assertion whose score was not computed at the current revision, so a
-- trip needs a score row to be visible at all. The three origins are `inferred`,
-- `explicit_addition` and `explicit_self_report`, and the last two both mean
-- *the person said it* — using either for a classifier's reading would be a lie
-- about who spoke.
--
-- **One trip is sufficient, so the figures are flat rather than computed.** The
-- owner's rule and the classifier agree: `scheduled_travel_to` carries
-- confidence 0.92 off a single strong ticket. A second trip to the same place
-- says "again", not "more true", so there is nothing to accumulate.
--
-- **The latest reading per item, never every reading.** Observations are
-- immutable, so a projector bump leaves the old projection beside the new one —
-- `place:saint_louis` from before the anchor rule is still in the vault next to
-- the row that correctly omits it. The writer takes `distinct on
-- (source_item_hmac) … order by created_at desc`, which is what stops a
-- superseded reading resurrecting a base as a holiday.

begin;

insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:scorer:v0.11.0'),
  'evidence_weighted_scorer', '0.11.0', 'scorer', null,
  '{"travel": "a place the calendar says somebody went to becomes a'
  ' scheduled_travel_to assertion against travel:*, with no observation'
  ' mapping and no evidence row; the latest projection per source item wins so'
  ' a superseded reading cannot resurrect a base as a holiday",'
  ' "travel_strength": 0.5,'
  ' "travel_confidence": 0.92,'
  ' "travel_needs_one_trip": true}'::jsonb,
  'active'
) on conflict (id) do nothing;

-- **Retired by role, not by name.** Naming the predecessor is the house style
-- and it is not replay-safe: if an earlier scorer migration is skipped, the
-- retire matches nothing, two versions stay active, and the assertion below
-- fails on a clean chain while passing in production. The intent — exactly one
-- active scorer — is stated directly instead.
update ontology.model_versions
   set status = 'retired'
 where model_role = 'scorer' and status = 'active' and version <> '0.11.0';

do $$
declare
  actives integer;
  enqueued integer;
begin
  select count(*) into actives
  from ontology.model_versions where model_role = 'scorer' and status = 'active';
  if actives <> 1 then
    raise exception 'expected exactly one active scorer, found %', actives;
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           'scorer 0.11.0: a trip is asserted'
         ) into enqueued;
  raise notice '0158: enqueued % recompute job(s)', enqueued;
end;
$$;

commit;
