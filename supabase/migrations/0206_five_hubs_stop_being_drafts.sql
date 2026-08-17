-- 0206 — five hubs stop being drafts.
--
-- ## What is wrong
--
-- Thirteen of this ontology's fifteen hubs are seeded vocabulary; ten are
-- `active` at the published version and **five have been `draft` since `0044`**.
-- `0044` records why in each row's `definition` column, and the reasons are
-- about evidence rather than about the hubs:
--
--     hub:games_play         'Not directly observed in the current V1 sources.'
--     hub:nature_outdoors    'Candidate hub.'
--     hub:work_study_making  'Confirmation-only in V0.'
--     hub:social_community   'Private by default.'
--     hub:animals_pets       'Pet health and personality remain explicit.'
--     hub:daily_rhythms      'Quantitative behavior, not identity.'
--
-- `hub:games_play` has since been activated, which is the precedent this follows:
-- a hub is drafted because nothing points at it, and activated when something
-- does. Two of the remaining five now have children — `work_study_making` holds
-- 37, of which 36 arrived with `0198`/`0199`'s Wikidata crafts slice, and
-- `daily_rhythms` holds 1.
--
-- **And the contract names one of them.** `compiled_semantic_contract_v1.json`
-- lists `hub:nature_outdoors` in `hub_canonical`, so
-- `compile_semantic_contract.py --check-database` has been reporting it as
-- missing from the ontology. It is not missing; it is unpublished. A gate that
-- stays red is one people stop reading, and the two ways to clear this were to
-- publish the hub or to stop naming it. Publishing is the one that also fixes
-- something.
--
-- ## What this does not fix, and the assertion that was blind to it
--
-- **The 36 crafts were never functionally stranded.**
-- `semantic_private.concept_block` climbs `broader` edges filtered on
-- `edge.status = 'active'` and never reads the *hub's* revision status, so
-- `0198` and `0199` both passed an assertion demanding every imported concept
-- reach a hub while parenting 36 of them to a draft one. The assertion was true
-- and blind: it asked whether a hub was reachable, not whether the hub was one
-- the ontology had adopted.
--
-- This migration ends by asserting the stronger thing — that no concept blocks
-- to a hub whose revision is not `active` — which after this change holds and
-- would have failed before it. That assertion is the durable half; activating
-- the hubs is what makes it passable.
--
-- ## What it costs, stated rather than discovered later
--
-- A new ontology version changes the `ontology_version_id` component of
-- `enqueue_recompute_on_analysis_change`'s idempotency key, which is what makes
-- the fleet re-scoreable — and until the worker runs, `api.list_assertions`
-- withholds every inferred assertion whose score was computed at the older
-- revision. **145 eligible assertions across three accounts go stale, and
-- Memories goes blank rather than stale, which is the design.** One worker
-- invocation restores them. This is the cheapest moment available: nothing is
-- shipped, nobody is reading that page, and the alternative is paying the same
-- cost later with users on it.
--
-- ## What is deliberately not touched
--
-- `sensitivity` and `inference_policy`. `work_study_making`, `social_community`
-- and `daily_rhythms` are `private`; `social_community`, `animals_pets` and
-- `daily_rhythms` are `review_required` and `work_study_making` is
-- `explicit_only`. Those columns are a separate judgement about what may be
-- inferred and shown, made in `0044` and not revisited here. **Publishing a hub
-- changes `status` and nothing else** — a container becoming available to file
-- terms under is not permission to assert anything about the person.
--
-- Hubs are never asserted regardless: `never_asserted_kinds` has included `hub`
-- since `0092`, and `0145`'s argument stands — a hub is not a claim that
-- somebody likes music, it is the drawer their music terms sit in.
--
-- ## The two traps `0199` records, both live here
--
-- **Five tables are copied forward, not four.** `external_concept_links` is the
-- one the standard pattern omits, and `0179` and `0180` both dropped it, taking
-- 550 links to 1 and destroying the provenance of every minted artist with
-- nothing raising. There are 760 at 0.32.0 and there must be 760 after.
--
-- **`publish_version` reads an `external` edge as a promise** that
-- `provenance->>'external_entity_id'` resolves in `ontology.external_entities`,
-- and fourteen edges that lied about it blocked the first real call in eighteen
-- versions. This migration mints no edges at all, so it cannot introduce one —
-- but the copy-forward carries every existing edge, so the publish still has to
-- accept them, and it will only if 0.32.0's were already honest.

begin;

do $$
declare
  current_version   text;
  old_version_id    uuid;
  next_version      text;
  new_version_id    uuid;
  activated         integer;
  revisions_copied  integer;
  labels_copied     integer;
  edges_copied      integer;
  motifs_copied     integer;
  links_before      integer;
  links_after       integer;
  drafted_hubs      integer;
  blocked_to_draft  integer;
  published_now     text;
  enqueued          integer;
  target            constant text[] := array[
    'hub:animals_pets', 'hub:daily_rhythms', 'hub:nature_outdoors',
    'hub:social_community', 'hub:work_study_making'
  ];
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';
  if current_version is null then
    raise exception '0206: no published ontology version to branch from';
  end if;

  select count(*) into links_before
    from ontology.external_concept_links where ontology_version_id = old_version_id;

  -- The five must actually be draft, or this migration is describing a state
  -- that no longer exists and should be read again rather than run.
  select count(*) into drafted_hubs
    from ontology.concept_revisions r
    join ontology.concepts c on c.id = r.concept_id
   where r.ontology_version_id = old_version_id
     and c.concept_key = any (target)
     and r.status = 'draft';
  if drafted_hubs = 0 then
    raise notice '0206: the five hubs are already active at %; nothing to publish',
      current_version;
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || (split_part(current_version, '.', 2)::integer + 1)::text || '.0';

  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Activate the five seeded hubs still drafted since 0044. '
          || 'Copied forward from ' || current_version || '.');
  select id into new_version_id from ontology.versions where version = next_version;

  -- ---- copy forward, five tables ----

  -- The revisions, with the five flipped on the way through. Everything else
  -- keeps the status it had.
  insert into ontology.concept_revisions
    (ontology_version_id, concept_id, preferred_label, concept_kind, definition,
     sensitivity, inference_policy, status, metadata)
  select new_version_id, r.concept_id, r.preferred_label, r.concept_kind, r.definition,
         r.sensitivity, r.inference_policy,
         case when c.concept_key = any (target) then 'active' else r.status end,
         r.metadata
    from ontology.concept_revisions r
    join ontology.concepts c on c.id = r.concept_id
   where r.ontology_version_id = old_version_id
  on conflict do nothing;
  get diagnostics revisions_copied = row_count;

  insert into ontology.concept_labels
    (ontology_version_id, concept_id, label, normalized_label, locale, label_type,
     provenance_type, confidence, status, external_ref)
  select new_version_id, l.concept_id, l.label, l.normalized_label, l.locale,
         l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
    from ontology.concept_labels l
   where l.ontology_version_id = old_version_id
  on conflict do nothing;
  get diagnostics labels_copied = row_count;

  insert into ontology.concept_edges
    (ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
     confidence, provenance_type, provenance, status)
  select new_version_id, e.subject_concept_id, e.predicate_key, e.object_concept_id,
         e.confidence, e.provenance_type, e.provenance, e.status
    from ontology.concept_edges e
   where e.ontology_version_id = old_version_id
  on conflict do nothing;
  get diagnostics edges_copied = row_count;

  -- `motif_rules.id` carries no default, unlike every other table copied here.
  insert into ontology.motif_rules
    (id, ontology_version_id, rule_key, evidence_target_concept_id, output_concept_id,
     evidence_predicate_key, output_predicate_key, rule_kind,
     minimum_independence_groups, minimum_strength, configuration, status)
  select extensions.gen_random_uuid(), new_version_id, m.rule_key, m.evidence_target_concept_id, m.output_concept_id,
         m.evidence_predicate_key, m.output_predicate_key, m.rule_kind,
         m.minimum_independence_groups, m.minimum_strength, m.configuration, m.status
    from ontology.motif_rules m
   where m.ontology_version_id = old_version_id
  on conflict do nothing;
  get diagnostics motifs_copied = row_count;

  -- **The one the pattern forgets.**
  insert into ontology.external_concept_links
    (ontology_version_id, concept_id, external_entity_id, link_type, confidence, status)
  select new_version_id, x.concept_id, x.external_entity_id, x.link_type,
         x.confidence, x.status
    from ontology.external_concept_links x
   where x.ontology_version_id = old_version_id
  on conflict do nothing;
  get diagnostics links_after = row_count;

  -- ---- what must be true before publishing ----

  if links_after <> links_before then
    raise exception '0206: carried % of % external concept links', links_after, links_before;
  end if;

  select count(*) into activated
    from ontology.concept_revisions r
    join ontology.concepts c on c.id = r.concept_id
   where r.ontology_version_id = new_version_id
     and c.concept_key = any (target)
     and r.status = 'active';
  if activated <> array_length(target, 1) then
    raise exception '0206: activated % of % hubs', activated, array_length(target, 1);
  end if;

  -- Nothing else changed status. The copy-forward is a copy, and a `case` in the
  -- middle of one is exactly where an unintended flip would hide.
  if exists (
    select 1
      from ontology.concept_revisions old_r
      join ontology.concept_revisions new_r
        on new_r.concept_id = old_r.concept_id
       and new_r.ontology_version_id = new_version_id
      join ontology.concepts c on c.id = old_r.concept_id
     where old_r.ontology_version_id = old_version_id
       and old_r.status is distinct from new_r.status
       and not (c.concept_key = any (target))
  ) then
    raise exception '0206: a concept other than the five changed status';
  end if;

  perform ontology.publish_version(new_version_id);

  select version into published_now from ontology.versions where status = 'published';
  if published_now is distinct from next_version then
    raise exception '0206: expected % published, found %', next_version, published_now;
  end if;

  -- ---- read back through the vocabulary, after publishing ----

  -- **The assertion `0198` and `0199` were blind to.** They demanded every
  -- imported concept reach a hub, and `concept_block` answers with one whether
  -- or not the ontology has adopted it — so 36 crafts satisfied it under a draft.
  -- Asked properly, this would have failed before this migration and passes now.
  select count(*) into blocked_to_draft
    from ontology.concept_revisions r
    join ontology.concepts hub
      on hub.concept_key = semantic_private.concept_block(r.concept_id, new_version_id)
    join ontology.concept_revisions hub_r
      on hub_r.concept_id = hub.id and hub_r.ontology_version_id = new_version_id
   where r.ontology_version_id = new_version_id
     and r.status = 'active'
     and hub_r.status <> 'active';
  if blocked_to_draft <> 0 then
    raise exception '0206: % active concept(s) still file under a hub that is not active',
      blocked_to_draft;
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           'ontology ' || next_version || ': the five drafted hubs are published'
         ) into enqueued;

  raise notice '0206: % published — % hubs activated, % revisions, % labels, % edges, '
               '% motifs, % links carried, % recompute job(s) enqueued',
    next_version, activated, revisions_copied, labels_copied, edges_copied,
    motifs_copied, links_after, enqueued;
end;
$$;

commit;
