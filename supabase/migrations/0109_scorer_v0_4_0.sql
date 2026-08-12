-- 0109 — scorer 0.4.0: a work clears a lower bar than a creator.
--
-- **The owner's reading of their own card, asked directly:** *"do not include
-- Re:Zero — recommendation is not reliable. Footloose is real."*
--
-- Both are now true, by two different mechanisms, which is the part worth
-- recording. **Re:Zero was never a claim at all**: its 52
-- `observation_mappings` are every one `mapping_state = 'candidate'` — fuzzy
-- near-misses from Bach passions and *Wicked* at 0.31–0.65 similarity, which
-- `score.py` filters out — and the concept's *name* came from a
-- `recommendation` row, which carries `action_weight` 0.000. The seeder no
-- longer reads those rows, so no further vocabulary is minted from what Apple
-- suggested.
--
-- **Footloose needed the bar to move.** `work:footloose_the_musical` scores
-- 0.266 on seven mappings against a flat 0.35, and the same strength means more
-- evidence for a work than for a creator: a creator accumulates across
-- everything they touch — Bach is on 417 mappings — while a work is attested
-- only by the songs belonging to it, and an album is one work and a dozen
-- artists. Judging both at 0.35 asks a cast recording to be as well evidenced
-- as a composer.
--
-- **0.20 rather than 0.25, and the reason is that a constant should not be
-- fitted to one row.** Footloose at 0.266 and BanG Dream! at 0.237 are one
-- mapping apart — seven against six — which is not a difference this scale can
-- resolve, so the bar goes below both rather than between them. It excludes the
-- four-mapping cluster (Bleach, Thousand-Year Blood War, MyGO), which is where a
-- franchise starts looking like one soundtrack somebody played, and it excludes
-- `work:re_zero` at 0.047 on a single song by a wide margin.

begin;

insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:scorer:v0.4.0'),
  'missing_aware_late_fusion', '0.4.0', 'scorer', null,
  '{"half_weight": 6.0, "half_observations": 4.0,'
  ' "eligible_strength": 0.35, "eligible_strength_by_kind": {"work": 0.20},'
  ' "classical_performer_min_albums": 2, "incidental_performer_weight": 0.02,'
  ' "never_asserted_kinds": ["hub"],'
  ' "withdraws_assertions": true,'
  ' "work_bar_rationale": "a creator accumulates across everything they touch;'
  ' a work is attested only by the songs belonging to it",'
  ' "stability": "0.0 on a first run; absence of observation is not evidence"}'::jsonb,
  'active'
) on conflict (id) do nothing;

update ontology.model_versions
   set status = 'retired'
 where model_role = 'scorer' and version = '0.3.0' and status = 'active';

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
  if newest <> '0.4.0' then
    raise exception 'finalization would pick scorer %, not 0.4.0', newest;
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
    'scorer 0.4.0: a work clears 0.20 where a creator clears 0.35'
  ) into enqueued;
  raise notice 'enqueued % recompute job(s) for the 0.4.0 scorer', enqueued;
end
$$;

commit;
