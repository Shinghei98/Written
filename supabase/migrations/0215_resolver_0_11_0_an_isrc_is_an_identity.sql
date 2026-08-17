-- 0215 — resolver 0.11.0: an ISRC is an identity.
--
-- ## Why a migration follows a code deploy
--
-- The ISRC route shipped in the Lambda and changed nothing, which is the
-- documented behaviour rather than a surprise: **deploying resolver code
-- re-scores nothing.** A run's identity is
-- `(user, revision, ontology version, resolver model, scorer model)` and carries
-- no code version, so `enqueue_recompute_on_analysis_change` looked for users
-- with no run at that tuple, found that every one already had one at `0.34.0`
-- under resolver `0.10.0`, and correctly enqueued nothing.
--
-- Three levers force a fresh run — a new distillation, a new ontology version, a
-- new model id — and the honest one here is the third. The resolver now reads a
-- structured identifier and writes an accepted `provider_id` mapping where it
-- previously wrote nothing at all. **A model version that lags its code makes
-- `semantic_runs` state something untrue**, so the version moves with the
-- behaviour.
--
-- ## What the parameter records
--
-- `parameters` is where a later reader looks, not a commit message. It says what
-- the route does *and* the two things it deliberately does not, because the
-- second list is the one that stops somebody widening this quietly:
--
--   * An ISRC identifies a **concrete recording**. It says nothing about the
--     composition behind it — a cover, a remaster and the original are three
--     ISRCs and one work — so no `recording_of` and no abstract `music_work`.
--   * The performer is a string on the concept's metadata and not a
--     `performed_by` edge, which would be a claim this route has not
--     established.
--
-- ## Ordering
--
-- Retiring 0.10.0 in the same migration, because the finalizer picks the newest
-- *active* model and leaving two active works by ordering — which is a
-- coincidence rather than a statement. Retirement is not deletion: the runs
-- computed under 0.10.0 keep pointing at it.

begin;

update ontology.model_versions set status = 'retired'
 where model_key = 'ontology_first_resolver' and status = 'active';

insert into ontology.model_versions (id, model_key, version, model_role, code_hash, parameters, status)
select extensions.gen_random_uuid(), 'ontology_first_resolver', '0.11.0', 'resolver', null,
       old.parameters || jsonb_build_object(
         'isrc_provider_id_route',
         'An observation carrying an ISRC is mapped to the recording concept '
         || 'that ISRC identifies, as an accepted mapping with '
         || 'mapping_method = provider_id. The join is through '
         || 'external_concept_links rather than by parsing the concept key, so '
         || 'the link is the fact and the key is a label. No string matching is '
         || 'involved and no title alias is consulted. '
         || 'It runs after the recency policy, so an action with no recency '
         || 'rule — Apple recommendation, action_weight 0.000 — is already '
         || 'dropped and cannot produce one. It runs before the lexical '
         || 'candidates, because it is not their fallback: an ISRC identifies '
         || 'the recording whatever its title matched, and observation_mappings '
         || 'is unique on (run, observation, concept, method) so both may stand. '
         || 'Evidence weight is 1.0, the observation''s own: there is no term to '
         || 'carry a role weight and inventing one would be a judgement about '
         || 'how much a recording counts, which belongs in action_weights. '
         || 'Deliberately not inferred: no abstract music_work and no '
         || 'recording_of, because an ISRC identifies a concrete recording and a '
         || 'cover, a remaster and the original are three ISRCs and one work; '
         || 'and no performed_by, the artist being a string on the concept''s '
         || 'metadata rather than a relation this route has established.'
       ),
       'active'
  from ontology.model_versions old
 where old.model_key = 'ontology_first_resolver' and old.version = '0.10.0'
on conflict (model_key, version) do update
   set parameters = ontology.model_versions.parameters || excluded.parameters,
       status = 'active';

do $$
declare
  actives  integer;
  enqueued integer;
  recordings integer;
begin
  select count(*) into actives
    from ontology.model_versions
   where model_key = 'ontology_first_resolver' and status = 'active';
  if actives <> 1 then
    raise exception '0215: expected one active resolver, found %', actives;
  end if;

  if not exists (
    select 1 from ontology.model_versions
     where model_key = 'ontology_first_resolver' and version = '0.11.0'
       and status = 'active' and parameters ? 'isrc_provider_id_route') then
    raise exception '0215: 0.11.0 is not the active resolver, or lost its parameter';
  end if;

  -- **There must be something for the route to find.** A resolver version
  -- published for a route with no vocabulary behind it would re-score the whole
  -- fleet to produce nothing, and the count is the difference between "the route
  -- found nothing" and "there was nothing to find".
  select count(*) into recordings
    from ontology.concepts c
    join ontology.concept_revisions cr on cr.concept_id = c.id
    join ontology.versions v on v.id = cr.ontology_version_id and v.status = 'published'
    join ontology.external_concept_links x
      on x.concept_id = c.id and x.ontology_version_id = v.id and x.status = 'active'
   where c.concept_key like 'recording:isrc_%' and cr.status = 'active';
  if recordings = 0 then
    raise exception '0215: no linked recording concept exists for the route to reach';
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           'resolver 0.11.0: an ISRC is mapped as an identity'
         ) into enqueued;

  raise notice '0215: % linked recording(s) reachable, % recompute job(s) enqueued',
    recordings, enqueued;
end;
$$;

commit;
