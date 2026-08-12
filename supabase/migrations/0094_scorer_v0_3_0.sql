-- 0094 — scorer 0.3.0: a claim the scorer stops making is withdrawn.
--
-- **The behaviour change.** `score.py` could raise an assertion and could not
-- lower one. Its eligibility test sat before the lookup, so `UPDATE_ASSERTION`
-- was reachable only with `state = 'eligible'` — and the comment above it,
-- *"an assertion that stops being evidenced becomes `inactive`"*, described
-- something the control flow made impossible. Two statements fix it, because a
-- concept can stop qualifying in two ways and only one of them is iterated:
-- scored-but-no-longer-eligible is demoted in the loop, and never-scored-at-all
-- is swept afterwards. The sweep is guarded on the run having scored something,
-- since a fallen-over resolver must not read as somebody who likes nothing.
--
-- **How it was found is the part worth keeping.** `0092` promoted a scorer that
-- refuses to assert hub concepts; `0093` enqueued the recompute; the run
-- executed under 0.2.0 — and `hub:music`, `hub:film_video` and
-- `hub:ideas_learning` came back `eligible`, untouched, still carrying
-- `updated_at` from the run before. The new rule was working perfectly on
-- concepts nobody had asserted yet, which is the population it was least needed
-- for. **A rule that only withholds arrives too late for exactly the rows it
-- was written for.**
--
-- **And this migration is the pattern `0093` asked for.** A model version and
-- the recompute it implies belong in one migration: promoting a model without
-- enqueuing changes what the system *would* compute and nothing it has
-- computed, which is the state `0092`/`0093` existed to escape. That this is
-- the second version bump in an hour is the discipline working rather than
-- churn — the scorer really did change twice, and a version that lags the code
-- is what made the first change unobservable.

begin;

insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:scorer:v0.3.0'),
  'missing_aware_late_fusion', '0.3.0', 'scorer', null,
  '{"half_weight": 6.0, "half_observations": 4.0, "eligible_strength": 0.35,'
  ' "classical_performer_min_albums": 2, "incidental_performer_weight": 0.02,'
  ' "never_asserted_kinds": ["hub"],'
  ' "withdraws_assertions": true,'
  ' "withdrawal_scope": "assertion_origin = inferred only; a declared assertion'
  ' is what a person said about themselves and no absence of evidence overrules it",'
  ' "withdrawal_guard": "a run that scored nothing withdraws nothing",'
  ' "stability": "0.0 on a first run; absence of observation is not evidence"}'::jsonb,
  'active'
) on conflict (id) do nothing;

update ontology.model_versions
   set status = 'retired'
 where model_role = 'scorer' and version = '0.2.0' and status = 'active';

do $$
declare
  active_scorers integer;
  newest text;
  enqueued integer;
begin
  select count(*) into active_scorers
  from ontology.model_versions where model_role = 'scorer' and status = 'active';
  if active_scorers <> 1 then
    raise exception 'expected exactly one active scorer, found %', active_scorers;
  end if;

  select version into newest
  from ontology.model_versions
  where model_role = 'scorer' and status = 'active'
  order by created_at desc, id
  limit 1;
  if newest <> '0.3.0' then
    raise exception 'finalization would pick scorer %, not 0.3.0', newest;
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
    'scorer 0.3.0: withdraws an assertion that stops being evidenced'
  ) into enqueued;
  raise notice 'enqueued % recompute job(s) for the 0.3.0 scorer', enqueued;
end
$$;

commit;
