-- 0153 — a ticket is a place, with no flight in front of it.
--
-- **A booked ticket is a standalone signal.** The classifier has always treated
-- one as a `booked_activity` and read its place straight off the location; no
-- flight is a prerequisite. What stopped Cancún reaching the vault was the
-- catalogue, which holds airport codes and city names for the twelve places a
-- *flight* can land at — and a hotel address is not one of them.
--
-- The row this is measured against is a real one:
--
--     Ticket: Chichén Itzá Premier Tour with Cenote Xunáan
--     Casa Tortugas Boutique Hotel — … Hotel Zone, Cancún, Quintana Roo, Mexico
--
-- `_resolve_place` matches a whole string, a three-letter code as a token, or a
-- multi-word alias at word boundaries — so the single token `Cancún` sitting
-- mid-sentence matched nothing, which is why the ticket classified correctly and
-- carried no place. The alias added in the classifier is `Cancún Quintana Roo`:
-- city with its region, because Quintana Roo also holds Tulum and Playa del
-- Carmen and mapping the state alone would file three different trips under one
-- name.
--
-- This mints the concept that alias points at. Without it the key resolves to
-- nothing, silently, which is the failure mode the ingestion catalogue already
-- warns about from the other side.

begin;

insert into ontology.versions (id, version, parent_version_id, status, description, published_at)
select gen_random_uuid(), '0.17.0', v.id, 'draft',
       'Cancún: a ticket names a place with no flight in front of it.', null
from ontology.versions v where v.version = '0.16.0'
on conflict (version) do nothing;

insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
select new_v.id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
from ontology.concept_revisions r
join ontology.versions old_v on old_v.id = r.ontology_version_id and old_v.version = '0.16.0'
cross join (select id from ontology.versions where version = '0.17.0') new_v
on conflict do nothing;

insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
select new_v.id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
from ontology.concept_labels l
join ontology.versions old_v on old_v.id = l.ontology_version_id and old_v.version = '0.16.0'
cross join (select id from ontology.versions where version = '0.17.0') new_v
on conflict do nothing;

insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
select new_v.id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
from ontology.concept_edges e
join ontology.versions old_v on old_v.id = e.ontology_version_id and old_v.version = '0.16.0'
cross join (select id from ontology.versions where version = '0.17.0') new_v
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
join ontology.versions old_v on old_v.id = m.ontology_version_id and old_v.version = '0.16.0'
cross join (select id from ontology.versions where version = '0.17.0') new_v
on conflict do nothing;

insert into ontology.concepts (id, concept_key)
values (gen_random_uuid(), 'place:cancun')
on conflict (concept_key) do nothing;

insert into ontology.concept_revisions (
  ontology_version_id, concept_id, preferred_label, concept_kind,
  sensitivity, inference_policy, status)
select v.id, c.id, 'Cancún', 'place', 'ordinary', 'review_required', 'active'
from ontology.concepts c
cross join (select id from ontology.versions where version = '0.17.0') v
where c.concept_key = 'place:cancun'
on conflict do nothing;

insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status, external_ref)
select v.id, c.id, 'Cancún', 'cancún', 'en', 'preferred', 'curated', 1.0, 'active', '{}'::jsonb
from ontology.concepts c
cross join (select id from ontology.versions where version = '0.17.0') v
where c.concept_key = 'place:cancun'
on conflict do nothing;

insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status, external_ref)
select v.id, c.id, 'place:cancun', 'place cancun', 'und', 'alternate', 'curated', 1.0, 'active', '{}'::jsonb
from ontology.concepts c
cross join (select id from ontology.versions where version = '0.17.0') v
where c.concept_key = 'place:cancun'
on conflict do nothing;

update ontology.versions set status = 'retired'
 where version = '0.16.0' and status = 'published';

update ontology.versions set status = 'published', published_at = now()
 where version = '0.17.0';

do $$
declare
  ok boolean;
  enqueued integer;
begin
  select exists (
    select 1 from ontology.concepts c
    join ontology.concept_revisions r on r.concept_id = c.id
    join ontology.versions v on v.id = r.ontology_version_id and v.status = 'published'
    where c.concept_key = 'place:cancun' and r.concept_kind = 'place' and r.status = 'active'
  ) into ok;
  if not ok then
    raise exception 'place:cancun is not active at the published version';
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           'ontology 0.17.0: a ticket names a place'
         ) into enqueued;
  raise notice '0153: place:cancun minted, % recompute job(s)', enqueued;
end;
$$;

commit;
