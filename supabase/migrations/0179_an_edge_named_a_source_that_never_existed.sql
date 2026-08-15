-- 0179 — an edge named a source that never existed.
--
-- ## What this fixes
--
-- `0177`'s mint fetches from Apple, writes its concepts and finishes by calling
-- `ontology.publish_version`, which refuses:
--
--     active external edge lacks resolvable provenance
--
-- Fourteen edges fail its test. They are the same fourteen in **every version
-- since 0.4.0**, carried by each copy-forward, and they are the hub attachments:
-- `genre:k_pop`, `cantopop`, `j_pop` and `mandopop` under `genre:asian_music`;
-- `asian_music` and `indie` under `hub:music`; the four game genres under
-- `hub:games_play`; `concept:technology`, `medium:television`,
-- `concept:humour` and `concept:tourism` under their own hubs.
--
-- ## What is actually wrong with them
--
-- `0076` wrote them `provenance_type = 'external'` with provenance
-- `{"source": "youtube_topics", "basis": "wikidata"}`. The guard reads that type
-- as a promise: *an outside record exists and this edge names it*, via
-- `provenance->>'external_entity_id'` resolving into `ontology.external_entities`.
--
-- **No such record exists, and none ever has.** Measured 2026-08-15:
--
-- | | |
-- |---|---|
-- | active edges in 0.21.0 | 2,942 `curated` + 14 `external` |
-- | of those 14, naming an entity | **0** |
-- | rows in `ontology.external_entities`, ever | **0** |
--
-- Nobody fetched anything from Wikidata. A person hand-wrote a hierarchy using
-- YouTube's topic taxonomy as the basis. The note recording that is honest; only
-- the *type* stamped on it claims something that did not happen.
--
-- ## Why this surfaces now, when the rows are eighteen versions old
--
-- **`publish_version` has been called twice in this repository's history** —
-- `0044`, publishing the original seed before any external edge existed, and
-- `0177`. Thirty-five migrations set `status = 'published'` directly instead. So
-- the guard has effectively never run, and the mint is the first thing to ask it
-- a real question. It answered correctly on its first genuine use, which is the
-- argument for keeping it rather than the argument for removing it.
--
-- ## This is a new version, because a published one cannot be edited
--
-- The first draft of this migration was one `update` against 0.21.0. It is
-- refused by `ontology.guard_published_version` — *"published or retired
-- ontology versions are immutable"* — and that refusal is correct: a version is
-- what everything scored against it was scored against, and editing one in place
-- would silently restate history. **So the same remedy has to be expressed the
-- only way the schema permits**: open a draft, copy the published version
-- forward with the fourteen retyped, and publish it through the guard.
--
-- **The minor position, `0.22.0`, because a human wrote it.** `0177` takes the
-- patch position for a machine mint, so the number says who minted a version
-- without anybody having to look it up. The next mint becomes `0.22.1`.
--
-- ## `curated`, and the two alternatives that were weighed
--
-- **Not fourteen `external_entities` rows.** That table holds a *fetched*
-- third-party record — `raw_payload`, `payload_hash`, `retrieved_at`,
-- `license_code`. Satisfying the check that way means inventing all four for
-- fetches that never happened, which converts a mislabel into fabricated
-- provenance and makes the check meaningless for every row after.
--
-- **Not relaxing the guard.** It is the only thing standing between a
-- copy-forward and an unprovenanced claim. A rule that is switched off the first
-- time it fires is not a rule. (Narrowing it to *rows a publish introduces* is a
-- separate and defensible change — it would defuse a future `expires_at` sweep
-- dangling an edge and freezing every publish — but it belongs after the data is
-- honest, not instead of it. Nothing deletes an entity row today and
-- `refresh_external_entity` has no handler, so that hazard is latent.)
--
-- **`curated` rather than `provider`**, because `0076` itself types the matching
-- *labels* `provider` — those are YouTube's own strings — while these edges are a
-- hierarchy somebody decided. `youtube_terms_relations.csv` types the identical
-- shape `curated`. Either value passes the guard; this one keeps one vocabulary
-- for one fact. The provenance JSON is untouched, so the basis survives.
--
-- ## The recompute, which the in-place edit would not have cost
--
-- A run's identity carries the ontology version, so publishing invalidates every
-- account's runs and each must be scored again. That is the price of the
-- immutability rule above and is charged here rather than being avoidable: the
-- enqueue at the foot is mandatory for any migration that publishes a version,
-- and ingestion is the only other thing that enqueues and cannot see a publish.
-- Nothing about the *scores* changes — no code reads an edge's `provenance_type`
-- — so the recompute recomputes the same numbers against a new identity.

begin;

do $$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  source_edges    integer;
  copied_edges    integer;
  unresolvable    integer;
  still_external  integer;
  basis_kept      integer;
  retyped         integer;
  published_now   text;
  enqueued        integer;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';
  if current_version is null then
    raise exception '0179: no published ontology version';
  end if;

  select count(*) into retyped
    from ontology.concept_edges
   where ontology_version_id = old_version_id and provenance_type = 'external';
  if retyped = 0 then
    raise exception '0179: nothing to retype in %, which is not the state this was written for', current_version;
  end if;

  select count(*) into source_edges
    from ontology.concept_edges where ontology_version_id = old_version_id;

  next_version := split_part(current_version, '.', 1) || '.'
               || (split_part(current_version, '.', 2)::integer + 1)::text || '.0';

  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Retype the fourteen youtube_topics broader edges from external to '
          || 'curated: they name no external entity and none has ever existed. '
          || 'Copied forward from ' || current_version || ' otherwise unchanged.');

  select id into new_version_id from ontology.versions where version = next_version;

  -- The same four tables the mint and `tools/seed_from_csv.py` copy, in the same
  -- order, so a reader comparing them sees one shape rather than two.
  insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
  select new_version_id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
    from ontology.concept_revisions r
   where r.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
  select new_version_id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
    from ontology.concept_labels l
   where l.ontology_version_id = old_version_id
  on conflict do nothing;

  -- **The one line this migration exists for.** Everything else is carried
  -- verbatim; `provenance` itself is untouched, so each retyped edge still says
  -- where it came from.
  insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
  select new_version_id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence,
         case when e.provenance_type = 'external' then 'curated' else e.provenance_type end,
         e.provenance, e.status
    from ontology.concept_edges e
   where e.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.motif_rules (
    id, ontology_version_id, rule_key, evidence_target_concept_id, output_concept_id,
    evidence_predicate_key, output_predicate_key, rule_kind,
    minimum_independence_groups, minimum_strength, configuration, status)
  select extensions.gen_random_uuid(), new_version_id, m.rule_key, m.evidence_target_concept_id,
         m.output_concept_id, m.evidence_predicate_key, m.output_predicate_key,
         m.rule_kind, m.minimum_independence_groups, m.minimum_strength,
         m.configuration, m.status
    from ontology.motif_rules m
   where m.ontology_version_id = old_version_id
  on conflict do nothing;

  -- **Nothing was dropped.** A retype must move a column, never a row: these
  -- fourteen are the hub attachments, and losing one would leave a genre
  -- floating under "Other" with nothing reporting it.
  select count(*) into copied_edges
    from ontology.concept_edges where ontology_version_id = new_version_id;
  if copied_edges <> source_edges then
    raise exception '0179: copied % edges from % — expected %',
      copied_edges, current_version, source_edges;
  end if;

  select count(*) into still_external
    from ontology.concept_edges
   where ontology_version_id = new_version_id and provenance_type = 'external';
  if still_external <> 0 then
    raise exception '0179: % external edge(s) survived the retype', still_external;
  end if;

  -- The basis survived, which is the whole reason this is a relabel rather than
  -- a deletion.
  select count(*) into basis_kept
    from ontology.concept_edges
   where ontology_version_id = new_version_id
     and provenance->>'source' = 'youtube_topics'
     and provenance->>'basis' = 'wikidata';
  if basis_kept <> retyped then
    raise exception '0179: % edges still name their basis, expected %', basis_kept, retyped;
  end if;

  -- The guard's own predicate, asked before the guard is asked. Passing here is
  -- passing there, and asking twice costs nothing.
  select count(*) into unresolvable
    from ontology.concept_edges edge
    left join ontology.external_entities entity
      on entity.id = nullif(edge.provenance->>'external_entity_id', '')::uuid
   where edge.ontology_version_id = new_version_id
     and edge.status = 'active'
     and edge.provenance_type = 'external'
     and entity.id is null;
  if unresolvable <> 0 then
    raise exception '0179: % edge(s) still lack resolvable provenance', unresolvable;
  end if;

  perform ontology.publish_version(new_version_id);

  select version into published_now from ontology.versions where status = 'published';
  if published_now is distinct from next_version then
    raise exception '0179: expected % published, found %', next_version, published_now;
  end if;

  -- Mandatory for anything that publishes a version: ingestion is the only other
  -- thing that enqueues, and it cannot see a publish.
  select semantic_private.enqueue_recompute_on_analysis_change(
           'ontology ' || next_version || ': youtube_topics broader edges retyped '
           || 'external -> curated'
         ) into enqueued;

  raise notice '0179: % published from %, % edges (% retyped), % recompute job(s)',
    next_version, current_version, copied_edges, retyped, enqueued;
end;
$$;

commit;
