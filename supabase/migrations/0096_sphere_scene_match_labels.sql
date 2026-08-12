-- 0096 — the labels the resolver actually matches on. Ontology 0.9.0.
--
-- **`0095` minted 35 concepts that could never resolve.** It gave each a prose
-- `preferred` label — *"English-language music"*, *"1970s English-language"* —
-- and the resolver emits the bare key suffix, `anglophone` and
-- `1970s_anglophone`, because that is what `era:*` established: `era:1970s`
-- carries an `alternate` label of exactly `1970s` and that is what a term
-- matches. Prose labels and suffix terms never meet.
--
-- **It would have failed silently and looked like a coverage problem.** An
-- unmatched term is not an error anywhere: `resolve_alias` returns nothing, the
-- mapping is skipped, and the run reports fewer mappings than expected. The
-- spheres would simply never have appeared, and the obvious diagnosis — *"the
-- library has no Cantopop"* — would have been wrong.
--
-- `0095`'s own assertions did not catch it because they counted concepts and
-- edges. Counting the right number of unreachable things is the failure mode of
-- a structural check, so the assertion below is about *resolvability*: every
-- concept this pair of migrations minted must carry a label equal to the term
-- the resolver emits for it.
--
-- **`alternate`, not `preferred`.** `0085` established that `preferred` and
-- `alternate` are the two auto-accepting types (`_AUTO_ACCEPT_ALIAS_TYPES` in
-- `graph.py`), and the prose label is the one a person should read on a card.
-- The suffix is a matching token, which is what an alternate is for.

begin;

insert into ontology.versions (id, version, parent_version_id, status, description, published_at)
select gen_random_uuid(), '0.9.0', v.id, 'draft',
       'Matchable labels for spheres and scenes.', null
from ontology.versions v where v.version = '0.8.0'
on conflict (version) do nothing;

insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
select new_v.id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
from ontology.concept_revisions r
join ontology.versions old_v on old_v.id = r.ontology_version_id and old_v.version = '0.8.0'
cross join (select id from ontology.versions where version = '0.9.0') new_v
on conflict do nothing;

insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
select new_v.id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
from ontology.concept_labels l
join ontology.versions old_v on old_v.id = l.ontology_version_id and old_v.version = '0.8.0'
cross join (select id from ontology.versions where version = '0.9.0') new_v
on conflict do nothing;

insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
select new_v.id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
from ontology.concept_edges e
join ontology.versions old_v on old_v.id = e.ontology_version_id and old_v.version = '0.8.0'
cross join (select id from ontology.versions where version = '0.9.0') new_v
on conflict do nothing;

insert into ontology.motif_rules (
  id, ontology_version_id, rule_key, evidence_target_concept_id, output_concept_id,
  evidence_predicate_key, output_predicate_key, rule_kind,
  minimum_independence_groups, minimum_strength, configuration, status)
select gen_random_uuid(), new_v.id, m.rule_key, m.evidence_target_concept_id,
       m.output_concept_id, m.evidence_predicate_key, m.output_predicate_key,
       m.rule_kind, m.minimum_independence_groups, m.minimum_strength,
       m.configuration, m.status
from ontology.motif_rules m
join ontology.versions old_v on old_v.id = m.ontology_version_id and old_v.version = '0.8.0'
cross join (select id from ontology.versions where version = '0.9.0') new_v
on conflict do nothing;

-- The suffix, derived from the key rather than retyped, so the alias and the
-- term the resolver emits cannot drift apart by a keystroke.
--
-- **`normalized_label` replaces `_` with a space, because `normalize_text` does
-- and this insert bypasses it.** A first draft stored `1970s_anglophone`
-- verbatim; the resolver normalizes its term to `1970s anglophone` before
-- looking it up, so the underscore form would have matched nothing — the exact
-- silent failure this migration exists to fix, reintroduced by the fix. It was
-- found because the same assertion, applied to `era:*`, flagged
-- `era:classical_period` as unreachable and it is not: it stores
-- `classical period` and resolves correctly. **The data was right and the check
-- was wrong**, which is the more useful half of the lesson.
--
-- `locale` is `und` to match every existing era alternate. These are matching
-- tokens rather than English prose; the prose sits on the `preferred` label
-- `0095` wrote, which is what a person reads.
insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status)
select v.id, c.id,
       split_part(c.concept_key, ':', 2),
       replace(split_part(c.concept_key, ':', 2), '_', ' '),
       'und', 'alternate', 'curated', 1.0, 'active'
from ontology.concepts c
cross join (select id from ontology.versions where version = '0.9.0') v
where c.concept_key like 'sphere:%' or c.concept_key like 'scene:%'
on conflict (ontology_version_id, concept_id, locale, normalized_label, label_type)
  do nothing;

do $$
declare
  unmatched text;
begin
  -- **Resolvability, not a count.** `0095` asserted 5 spheres, 30 scenes and 60
  -- edges and all three passed while every one of them was unreachable. What
  -- has to be true is that the term the resolver emits — the key's suffix —
  -- finds a label.
  select string_agg(c.concept_key, ', ' order by c.concept_key) into unmatched
  from ontology.concepts c
  cross join (select id from ontology.versions where version = '0.9.0') v
  where (c.concept_key like 'sphere:%' or c.concept_key like 'scene:%')
    and not exists (
      select 1 from ontology.concept_labels l
       where l.concept_id = c.id
         and l.ontology_version_id = v.id
         and l.status = 'active'
         and l.normalized_label = replace(split_part(c.concept_key, ':', 2), '_', ' ')
    );
  if unmatched is not null then
    raise exception 'these would resolve to nothing: %', unmatched;
  end if;

  -- The same property for the vocabulary that established the pattern, so a
  -- future change to how a term is spelled fails here rather than quietly
  -- emptying the eras too.
  select string_agg(c.concept_key, ', ' order by c.concept_key) into unmatched
  from ontology.concepts c
  cross join (select id from ontology.versions where version = '0.9.0') v
  where c.concept_key like 'era:%'
    and not exists (
      select 1 from ontology.concept_labels l
       where l.concept_id = c.id
         and l.ontology_version_id = v.id
         and l.status = 'active'
         and l.normalized_label = replace(split_part(c.concept_key, ':', 2), '_', ' ')
    );
  if unmatched is not null then
    raise exception 'eras would resolve to nothing: %', unmatched;
  end if;
end
$$;

update ontology.versions set status = 'retired'
 where version = '0.8.0' and status = 'published';

update ontology.versions set status = 'published', published_at = now()
 where version = '0.9.0';

commit;
