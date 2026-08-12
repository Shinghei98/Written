-- 0098 — resolver 0.2.0: spheres, scenes, composer periods, and the marked genre.
--
-- **The same discipline `0092` established for the scorer.**
-- `ontology_first_resolver` 0.1.0 has been the recorded resolver since
-- 2026-08-11 while the code behind it changed repeatedly — album-breadth
-- performer weighting, `exact_terms_only`, and now three more things. A run
-- records which resolver computed it precisely so a mapping is attributable,
-- and a version that lags the code makes that column state something untrue.
--
-- What changed since 0.1.0, recorded in `parameters` where a later reader will
-- look rather than in a commit message:
--
--   * `sphere:*` and `scene:*` terms — a decade is an axis, the composite is
--     the claim.
--   * `COMPOSER_PERIODS` — Apple files the Bach passions as plain `Classical`,
--     so classical rows had no era at all and the six period concepts had zero
--     assertions since `0044`.
--   * **the marked-genre rule**, which is the one that could not wait. Apple
--     writes both the specific genre and the broad one: Frankie Kao's rows read
--     `Mandopop|Music|Pop`. Read as equals, a Taiwanese singer produced
--     `sphere:anglophone` and his five 1970s rows became evidence for
--     `scene:1970s_anglophone`, which then carried all thirteen of
--     `era:1970s`'s mappings. The composite spanned exactly the worlds it was
--     built to separate, and the ontology 0.9.0 run has that state stored.
--
-- Publishing an ontology version was enough to force the first re-score;
-- nothing about the ontology changed since, so the resolver's own version is
-- the honest lever — the mappings really would be different.

begin;

insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:resolver:v0.2.0'),
  'ontology_first_resolver', '0.2.0', 'resolver', null,
  '{"min_tag_length": 3, "whole_tag_only": true, "fuzzy": false,'
  ' "exact_terms_only": true,'
  ' "classical_performer_min_albums": 2, "incidental_performer_weight": 0.02,'
  ' "composer_periods": true,'
  ' "spheres": ["anglophone", "cantonese", "mandarin", "japanese", "korean"],'
  ' "scene": "decade x sphere; classical periods are never crossed",'
  ' "marked_genre_wins": "a row stating Mandopop|Pop is Mandopop; the unmarked'
  ' genres speak only when no marked one is present on that row"}'::jsonb,
  'active'
) on conflict (id) do nothing;

update ontology.model_versions
   set status = 'retired'
 where model_role = 'resolver' and version = '0.1.0' and status = 'active';

do $$
declare
  active_resolvers integer;
  newest text;
  enqueued integer;
begin
  select count(*) into active_resolvers
  from ontology.model_versions where model_role = 'resolver' and status = 'active';
  if active_resolvers <> 1 then
    raise exception 'expected exactly one active resolver, found %', active_resolvers;
  end if;

  select version into newest
  from ontology.model_versions
  where model_role = 'resolver' and status = 'active'
  order by created_at desc, id
  limit 1;
  if newest <> '0.2.0' then
    raise exception 'finalization would pick resolver %, not 0.2.0', newest;
  end if;

  -- The call `0095` and `0096` owed and `0097` had to supply separately. Doing
  -- it here is the pattern working rather than a fix.
  select semantic_private.enqueue_recompute_on_analysis_change(
    'resolver 0.2.0: marked-genre rule, spheres, scenes, composer periods'
  ) into enqueued;
  raise notice 'enqueued % recompute job(s) for resolver 0.2.0', enqueued;
end
$$;

commit;
