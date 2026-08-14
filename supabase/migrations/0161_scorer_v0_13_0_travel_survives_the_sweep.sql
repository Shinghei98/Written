-- 0161 — scorer 0.13.0: a trip survives the sweep that retires unscored claims.
--
-- `0160` tried to re-score by enqueuing alone and enqueued nothing, correctly:
-- `enqueue_recompute_on_analysis_change` only enqueues where no run exists for
-- `(user, revision, ontology version, resolver, scorer)`, and the fix changed
-- code rather than any of those. **Deploying code re-scores nothing** — the
-- three levers are a new distillation, a new ontology version or a new model
-- id, and a model version that lags its code makes `semantic_runs` state
-- something untrue.
--
-- The defect it carries: `DEMOTE_UNSCORED_ASSERTIONS` sets `inactive` every
-- `affinity_to` assertion whose concept the run did not score, and a trip is
-- scored by the travel writer rather than by the concept loop — so both trips
-- were swept moments after being written, inside the same transaction. Two
-- assertions, two score versions, two current scores, all `inactive`, and the
-- job reported success. The writer now returns its concepts and the caller adds
-- them to `scored_concepts`.

begin;

insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:scorer:v0.13.0'),
  'evidence_weighted_scorer', '0.13.0', 'scorer', null,
  '{"travel": "a place the calendar says somebody went to becomes an'
  ' affinity_to assertion against travel:*, suggested rather than confirmed and'
  ' struck off by the person if wrong; scored outside the concept loop and'
  ' therefore added to scored_concepts, or the unscored sweep retires it in the'
  ' same transaction that writes it",'
  ' "travel_predicate": "affinity_to",'
  ' "travel_strength": 0.5,'
  ' "travel_confidence": 0.92,'
  ' "travel_needs_one_trip": true}'::jsonb,
  'active'
) on conflict (id) do nothing;

update ontology.model_versions
   set status = 'retired'
 where model_role = 'scorer' and version = '0.12.0' and status = 'active';

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
           'scorer 0.13.0: trips survive the unscored sweep'
         ) into enqueued;
  raise notice '0161: enqueued % recompute job(s)', enqueued;
end;
$$;

commit;
