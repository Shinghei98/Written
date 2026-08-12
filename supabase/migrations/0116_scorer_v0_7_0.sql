-- 0116 — scorer 0.7.0: the transfer is symmetric across named roles.
--
-- `0114` shipped it as creator-only: strike off the singer, the composer and
-- the work gain. **The first suppression anybody made was a composer** — Frank
-- Wildhorn, who has no `creator` mapping at all, being the writer of *Jekyll &
-- Hyde* — so the rule did nothing for the one real case in the database.
--
-- Striking off the writer says the same kind of thing as striking off the
-- singer, so the rule is now "a *different* named role on the same row":
-- `creator`, `composer` and `source_work` all free weight, and all receive it,
-- and never from a role to itself. Same role is what would let one cast member's
-- removal promote the other five, who are in the identical ambiguous position.
--
-- Measured on the real suppression before deploying: Wildhorn's weight moves to
-- *Musical Jekyll & Hyde* (2.993) and to the cast who sang it — Kwang-Ho Hong
-- 1.327, Yoon Gong Joo 0.737, 류정한 0.536. Which is the sentence "I don't like
-- the writer, I like this recording", arrived at without a constant.
begin;

insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:scorer:v0.7.0'),
  'missing_aware_late_fusion', '0.7.0', 'scorer', null,
  '{"half_weight": 6.0, "half_observations": 4.0,'
  ' "eligible_strength": 0.35, "eligible_strength_by_kind": {"work": 0.25},'
  ' "classical_performer_min_albums": 2, "incidental_performer_weight": 0.02,'
  ' "never_asserted_kinds": ["hub"], "withdraws_assertions": true,'
  ' "suppression_transfer": {'
  '   "roles": ["creator", "composer", "source_work"],'
  '   "rule": "freed weight goes to a different named role on the same row,'
  ' apportioned by existing weight there; never to the same role, never to'
  ' genre, era, scene or sphere; no constant",'
  '   "applied": "before saturation"}}'::jsonb,
  'active'
) on conflict (id) do nothing;

update ontology.model_versions set status = 'retired'
 where model_role = 'scorer' and version = '0.6.0' and status = 'active';

do $$
declare newest text; enqueued integer;
begin
  select version into newest from ontology.model_versions
   where model_role='scorer' and status='active' order by created_at desc, id limit 1;
  if newest <> '0.7.0' then
    raise exception 'finalization would pick scorer %, not 0.7.0', newest;
  end if;
  select semantic_private.enqueue_recompute_on_analysis_change(
    'scorer 0.7.0: the suppression transfer is symmetric across named roles'
  ) into enqueued;
  raise notice 'enqueued % recompute job(s)', enqueued;
end
$$;
commit;
