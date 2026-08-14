-- 0159 — scorer 0.12.0: a trip is suggested, and can be struck off.
--
-- **The owner's ruling, 2026-08-14: treat a trip like any other term.** Assert
-- it, show it, and let the person strike it off if it is wrong — the same
-- correction a creator or a content creator already has. Being wrong in public
-- and corrected is how the model learns which evidence means what, and the long
-- game is latent correlation no hand-written rule would have found.
--
-- **`0158` claimed this and did not do it**, which is why 0.12.0 follows so
-- closely: its writer asserted `scheduled_travel_to`, which is
-- `relation_class = 'observed_action'` with `assertion_safe = false` — what
-- somebody did is evidence, not a claim about them — and a guard refused it
-- with *"must be a user_claim"*. That failed the whole job rather than the
-- travel step, so every user's scoring stopped for a term nobody could yet see.
-- A model version that claims a behaviour the code does not have makes
-- `semantic_runs` state something untrue, so this supersedes it rather than
-- editing it.
--
-- **The predicate is `affinity_to`.** `travel_interest` is the obvious choice
-- and its own description forbids exactly this use — *"never entailed by a
-- booking alone"* — so taking it would mean overriding a sentence written to
-- prevent it, silently. `affinity_to` is `assertion_safe` and means *"defeasible
-- or explicit user affinity"*: defeasible is the whole model here, a claim that
-- stands until its subject overturns it. It is also the owner's own framing,
-- that a place is an affinity unless it is a travel.
--
-- Nothing about the calendar guards changes: no `observation_mappings` row, no
-- `assertion_evidence` row, and the assertion is recognised by its predicate,
-- which is the shape `assertion_has_calendar_evidence` already anticipates.

begin;

insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:scorer:v0.12.0'),
  'evidence_weighted_scorer', '0.12.0', 'scorer', null,
  '{"travel": "a place the calendar says somebody went to becomes an'
  ' affinity_to assertion against travel:*, suggested rather than confirmed and'
  ' struck off by the person if wrong; no observation mapping and no evidence'
  ' row, and the latest projection per source item wins so a superseded reading'
  ' cannot resurrect a base as a holiday",'
  ' "travel_predicate": "affinity_to",'
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
 where model_role = 'scorer' and status = 'active' and version <> '0.12.0';

do $$
declare
  actives integer;
  safe boolean;
  enqueued integer;
begin
  select count(*) into actives
  from ontology.model_versions where model_role = 'scorer' and status = 'active';
  if actives <> 1 then
    raise exception 'expected exactly one active scorer, found %', actives;
  end if;

  -- **Checked here because the worker cannot check it in time.** A predicate
  -- that is not assertion-safe fails inside the job, which fails the whole
  -- recompute — the way 0.11.0 did.
  select rt.assertion_safe into safe
  from ontology.relation_types rt where rt.predicate_key = 'affinity_to';
  if not coalesce(safe, false) then
    raise exception 'affinity_to is not assertion_safe';
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           'scorer 0.12.0: a trip is suggested and can be struck off'
         ) into enqueued;
  raise notice '0159: enqueued % recompute job(s)', enqueued;
end;
$$;

commit;
