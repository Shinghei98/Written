-- 0092 — the scorer changed, so the scorer has a version.
--
-- **This is what `ontology.model_versions` is for, and it took a stuck run to
-- notice.** `missing_aware_late_fusion` 0.1.0 has produced eight runs. The code
-- behind it has changed twice since — classical performers weighed by album
-- breadth, and hubs scored but never asserted — while the recorded version
-- stayed put. Every one of those eight runs claims to have been computed by
-- 0.1.0, and three of them were computed by something else.
--
-- **The practical half.** `semantic_run_live_identity_idx` keys a run on
-- `(user, ontology version, resolver model, scorer model, input_revision,
-- input_hash)`. The code version is deliberately not in it, so a deploy
-- re-scores nothing and a re-run against unchanged input returns
-- `already_resolved` — correct for idempotency, and it means a behaviour change
-- with no version change is *unobservable*. The library stopped changing
-- (revision 18 for several distillations running), so no distillation could
-- move it either. A new scorer version is the honest lever rather than a
-- workaround: the identity changes because the scorer genuinely is different.
--
-- **Retired rather than left active**, because `finalize_ingestion_run_v031`
-- picks the newest *active* scorer (`order by created_at desc, id limit 1`).
-- Leaving both active would work by ordering, which is a coincidence rather
-- than a statement. 0.1.0 no longer describes any code that exists.
--
-- The eight runs it produced keep pointing at it: `on delete restrict` protects
-- them, retirement is not deletion, and a run recording which scorer computed
-- it is the whole reason the column exists.

begin;

insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:scorer:v0.2.0'),
  'missing_aware_late_fusion', '0.2.0', 'scorer', null,
  -- The parameters are the behaviour, recorded where a later reader will look
  -- for it rather than in a commit message.
  '{"half_weight": 6.0, "half_observations": 4.0, "eligible_strength": 0.35,'
  ' "classical_performer_min_albums": 2, "incidental_performer_weight": 0.02,'
  ' "never_asserted_kinds": ["hub"],'
  ' "stability": "0.0 on a first run; absence of observation is not evidence"}'::jsonb,
  'active'
) on conflict (id) do nothing;

update ontology.model_versions
   set status = 'retired'
 where model_role = 'scorer' and version = '0.1.0' and status = 'active';

do $$
declare
  active_scorers integer;
  newest text;
begin
  select count(*) into active_scorers
  from ontology.model_versions where model_role = 'scorer' and status = 'active';
  if active_scorers <> 1 then
    raise exception 'expected exactly one active scorer, found %', active_scorers;
  end if;

  -- The selection `finalize_ingestion_run_v031` performs, asserted here so a
  -- future insert that lands with an older `created_at` fails now rather than
  -- silently scoring with the wrong model.
  select version into newest
  from ontology.model_versions
  where model_role = 'scorer' and status = 'active'
  order by created_at desc, id
  limit 1;
  if newest <> '0.2.0' then
    raise exception 'finalization would pick scorer %, not 0.2.0', newest;
  end if;

  -- Retirement must not orphan the runs that named it.
  if not exists (
    select 1 from semantic_private.semantic_runs r
    join ontology.model_versions m on m.id = r.scorer_model_id
    where m.version = '0.1.0'
  ) then
    raise exception 'the eight runs computed by 0.1.0 no longer reference it';
  end if;
end
$$;

commit;
