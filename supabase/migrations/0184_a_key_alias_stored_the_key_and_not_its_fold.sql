-- 0184 — a key alias stored the key and not its fold.
--
-- ## The last link, and it was unmatchable from the day it was written
--
-- With the phone finally sending them, `Hearthstone` reached the vault in
-- Kripparrian's channel keywords, the run allowed uploader tags, the lane fired
-- — and produced **zero mappings**. Not refused, not scored low. Absent.
--
-- The `uploader_tag_work` lane emits a concept *key* rather than the tag, which
-- `0149` arranged to resolve by giving every catalogue concept its own key as an
-- `alternate` label. But those rows stored the key verbatim as the
-- `normalized_label`:
--
--     label              work:hearthstone
--     normalized_label   work:hearthstone     <- stored
--     normalize_text()   work hearthstone     <- what the resolver looks for
--
-- `normalize_text` is a Unicode-category fold: it turns punctuation into spaces,
-- so the colon and the underscores go. The resolver computes it on every term
-- (`_term`, `normalized=normalize_text(text)`) and matches whole normalized
-- labels — so the stored form could never be met by the emitted one.
--
-- **This is `0096`'s defect exactly, and the file that warns about it names it:**
-- *"an alias whose stored form differs from what the resolver computes is minted
-- unmatchable with nothing reporting it."* Three concepts, silent since `0149`.
--
-- ## Three, and how they were found
--
-- 31 active labels in the published ontology contain a colon; **three** have a
-- colon still in their *normalized* form, and they are the three game works:
-- `work:hearthstone`, `work:world_of_warcraft`, `work:final_fantasy_xiv`. Every
-- other colon-bearing label was folded correctly, which is what makes these
-- three a defect rather than a convention.
--
-- The corrected values are computed by `normalize_text` and written here as
-- literals, because SQL cannot reproduce the fold — the same reason
-- `tools/apple_catalog.py` computes the normalised form for the mint rather than
-- leaving it to the migration.
--
-- ## Why a version rather than an update
--
-- A published ontology version is immutable (`guard_published_version`), so the
-- correction copies forward: `0.24.0`. The three rows change only their
-- `normalized_label`; the labels, the concepts, their parents and every mapping
-- resting on them are untouched.

begin;

do $$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  source_labels   integer;
  copied_labels   integer;
  still_raw       integer;
  fixed           integer;
  enqueued        integer;
  published_now   text;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  select count(*) into still_raw
    from ontology.concept_labels
   where ontology_version_id = old_version_id
     and status = 'active' and normalized_label like '%:%';
  if still_raw = 0 then
    raise exception '0184: nothing to correct in %, which is not the state this describes',
      current_version;
  end if;

  select count(*) into source_labels
    from ontology.concept_labels where ontology_version_id = old_version_id;

  next_version := split_part(current_version, '.', 1) || '.'
               || (split_part(current_version, '.', 2)::integer + 1)::text || '.0';

  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Key aliases stored the key verbatim where the resolver computes a '
          || 'Unicode fold, so three game works could never be matched. Copied '
          || 'forward from ' || current_version || '.');
  select id into new_version_id from ontology.versions where version = next_version;

  insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
  select new_version_id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
    from ontology.concept_revisions r
   where r.ontology_version_id = old_version_id
  on conflict do nothing;

  -- **The one line this exists for.** Only the normalised form moves; the label
  -- itself stays the key, because that is what `0149` deliberately shows a
  -- reader and what the lane emits.
  insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
  select new_version_id, l.concept_id, l.label,
         case l.normalized_label
           when 'work:hearthstone'       then 'work hearthstone'
           when 'work:world_of_warcraft' then 'work world of warcraft'
           when 'work:final_fantasy_xiv' then 'work final fantasy xiv'
           else l.normalized_label
         end,
         l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
    from ontology.concept_labels l
   where l.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
  select new_version_id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
    from ontology.concept_edges e
   where e.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.motif_rules (id, ontology_version_id, rule_key, evidence_target_concept_id, output_concept_id, evidence_predicate_key, output_predicate_key, rule_kind, minimum_independence_groups, minimum_strength, configuration, status)
  select extensions.gen_random_uuid(), new_version_id, m.rule_key, m.evidence_target_concept_id, m.output_concept_id, m.evidence_predicate_key, m.output_predicate_key, m.rule_kind, m.minimum_independence_groups, m.minimum_strength, m.configuration, m.status
    from ontology.motif_rules m
   where m.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.external_concept_links (ontology_version_id, concept_id, external_entity_id, link_type, confidence, status)
  select new_version_id, x.concept_id, x.external_entity_id, x.link_type, x.confidence, x.status
    from ontology.external_concept_links x
   where x.ontology_version_id = old_version_id
  on conflict do nothing;

  -- Nothing lost, and the three actually corrected.
  select count(*) into copied_labels
    from ontology.concept_labels where ontology_version_id = new_version_id;
  if copied_labels <> source_labels then
    raise exception '0184: copied % labels, expected %', copied_labels, source_labels;
  end if;

  select count(*) into still_raw
    from ontology.concept_labels
   where ontology_version_id = new_version_id
     and status = 'active' and normalized_label like '%:%';
  if still_raw <> 0 then
    raise exception '0184: % active alias(es) still hold an unfolded key', still_raw;
  end if;

  select count(*) into fixed
    from ontology.concept_labels
   where ontology_version_id = new_version_id
     and normalized_label in ('work hearthstone', 'work world of warcraft',
                              'work final fantasy xiv');
  if fixed <> 3 then
    raise exception '0184: expected 3 corrected aliases, found %', fixed;
  end if;

  perform ontology.publish_version(new_version_id);

  select version into published_now from ontology.versions where status = 'published';
  if published_now is distinct from next_version then
    raise exception '0184: expected % published, found %', next_version, published_now;
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           'ontology ' || next_version || ': key aliases carry their fold'
         ) into enqueued;

  raise notice '0184: % published, 3 aliases corrected, % recompute job(s)',
    next_version, enqueued;
end;
$$;

commit;
