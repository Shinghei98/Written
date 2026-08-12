-- 0110 — scorer 0.5.0: the work bar moves to 0.25, on a label rather than a guess.
--
-- **`0109` put it at 0.20 and said why it was not 0.25**: Footloose at 0.266 on
-- seven mappings and BanG Dream! at 0.237 on six are one mapping apart, which is
-- not a difference the scale can resolve, so splitting them would have been
-- fitting a constant to a single data point.
--
-- Shown the result, the owner judged the second row: *"BanG Dream shouldn't be
-- there, move it to 0.25."* That is exactly what the earlier caution was
-- waiting for. **What was missing was a label on the second point, not a finer
-- threshold** — with both judged, 0.25 separates two labelled rows rather than
-- guessing between two unlabelled ones, and the reasoning in `0109` stands
-- rather than being overturned.
--
-- Three works are now judged and the bar honours all three: Footloose in at
-- 0.266, BanG Dream! out at 0.237, Re:Zero out at 0.047 — the last needing no
-- threshold at all, since every one of its mappings is a fuzzy `candidate` and
-- its name came from a `recommendation`.
--
-- **Still one library and one reviewer.** This is a judgement, not a
-- measurement, and it will only become one against somebody else's music.

begin;

insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:scorer:v0.5.0'),
  'missing_aware_late_fusion', '0.5.0', 'scorer', null,
  '{"half_weight": 6.0, "half_observations": 4.0,'
  ' "eligible_strength": 0.35, "eligible_strength_by_kind": {"work": 0.25},'
  ' "classical_performer_min_albums": 2, "incidental_performer_weight": 0.02,'
  ' "never_asserted_kinds": ["hub"],'
  ' "withdraws_assertions": true,'
  ' "work_bar_basis": "owner judgement on three works of their own: Footloose in'
  ' at 0.266, BanG Dream out at 0.237, Re:Zero out at 0.047",'
  ' "stability": "0.0 on a first run; absence of observation is not evidence"}'::jsonb,
  'active'
) on conflict (id) do nothing;

update ontology.model_versions
   set status = 'retired'
 where model_role = 'scorer' and version = '0.4.0' and status = 'active';

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
  if newest <> '0.5.0' then
    raise exception 'finalization would pick scorer %, not 0.5.0', newest;
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
    'scorer 0.5.0: the work bar is 0.25, set from the owner''s judgement'
  ) into enqueued;
  raise notice 'enqueued % recompute job(s) for the 0.5.0 scorer', enqueued;
end
$$;

commit;
