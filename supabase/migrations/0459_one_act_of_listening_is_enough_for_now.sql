-- 0459 — one act of listening is enough, for now.
--
-- **The owner's direction, 2026-08-28: make the works bar very low — one
-- weak evidence clears — and calibrate later.** `0.25` (a total weight of
-- ~2.0, five or six songs from one work) was fitted to one library and one
-- reviewer, and it kept every single-OST franchise at `candidate` forever:
-- Attack on Titan at 0.042 on one saved track, Persona 5 at 0.12, Genshin
-- at 0.10 — exactly the works the watchable-media bio layer exists to
-- compare, none of them ever crossing. The new bar is 0.03: just under the
-- weakest single-track work measured (0.042), above the propagated λ-dust,
-- so one real act of listening clears and a graph echo does not.
--
-- The code moves in the same change (`ELIGIBLE_STRENGTH_BY_KIND` in
-- `score.py`), and this migration is what makes the deploy real: a run's
-- identity carries the scorer model id, so without a new model row nothing
-- re-scores and the bar exists only in a diff. Scorer `0.25.0` supersedes
-- `0.24.2`; retired, never deleted; the recompute is asked for at the end,
-- which since 0452 terminates.

begin;

do $$
declare old_row ontology.model_versions%rowtype;
begin
  select * into old_row from ontology.model_versions
   where model_role = 'scorer' and status = 'active'
   order by created_at desc limit 1;
  if old_row.id is null then
    raise notice '0459: no active scorer stands; the model rows wait';
  else
    update ontology.model_versions set status = 'retired'
     where id = old_row.id;
    insert into ontology.model_versions
      (id, model_key, version, model_role, status, parameters)
    values (extensions.gen_random_uuid(), old_row.model_key,
            '0.25.0', 'scorer', 'active',
            coalesce(old_row.parameters, '{}'::jsonb)
              || jsonb_build_object('work_eligible_strength',
                   '0.03 — owner 2026-08-28: one weak direct evidence is '
                   || 'enough for now, deliberately uncalibrated; the 0.25 '
                   || 'judgement of 0223 stands superseded until more '
                   || 'libraries calibrate it'));
  end if;
end;
$$;

do $$
begin
  perform semantic_private.enqueue_recompute_on_analysis_change(
    '0459: the works bar drops to 0.03 — one act of listening clears');
end;
$$;

commit;
