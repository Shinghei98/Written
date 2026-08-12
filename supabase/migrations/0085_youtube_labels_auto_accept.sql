-- 0085 — the YouTube topic labels would have resolved and counted for nothing.
--
-- **`0076` picked the wrong `label_type`, and the effect is silent.**
-- `written_ontology.graph` auto-accepts only two kinds:
--
--     _AUTO_ACCEPT_ALIAS_TYPES = {"preferred", "alternate"}
--
-- A match on any other type resolves to `MappingState.CANDIDATE` rather than
-- `ACCEPTED` — and `score.py` aggregates `mapping_state = 'accepted'`. So all
-- twenty provider topics would have resolved correctly, been stored as
-- candidates, and contributed **zero evidence**, with every count downstream
-- looking plausible and no error anywhere.
--
-- **The diagnosis is that one axis was used to encode the other.**
-- `provenance_type` already records *who supplied* a term — `provider`, for
-- these. `label_type` records *what kind of name* it is, and `Music_of_Asia` is
-- an alternate name for Asian music. Writing `source_term` said "this came from
-- a source" a second time, in the column that decides whether the mapping is
-- trusted. This codebase's own "two columns that accept the same words" defect,
-- with the columns being two different questions rather than two meanings.
--
-- `provenance_type` stays `provider` and `external_ref` keeps the QID, so
-- nothing about where these came from is lost — only the claim that they are
-- unreviewed, which was never true: every one is a hand-authored mapping in
-- `tools/youtube_topics.py`.
--
-- **The collision that looked certain does not happen.** `Film` normalizes to
-- `film`, which `hub:film_video` already carries as `alternate`/`curated` — but
-- the unique key includes `locale`, these are `und` and that one is `en`, so
-- both survive. The `on conflict do nothing` below is kept as the guard it was
-- meant to be rather than removed as unreachable: it costs nothing and the next
-- provider vocabulary may well land in `en`.
--
-- A published version is immutable, so this mints 0.6.0 rather than editing
-- 0.5.0 in place.

begin;

insert into ontology.versions (id, version, parent_version_id, status, description, published_at)
select gen_random_uuid(), '0.6.0', v.id, 'draft',
       'YouTube provider labels made auto-acceptable.', null
from ontology.versions v where v.version = '0.5.0'
on conflict (version) do nothing;

insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
select new_v.id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
from ontology.concept_revisions r
join ontology.versions old_v on old_v.id = r.ontology_version_id and old_v.version = '0.5.0'
cross join (select id from ontology.versions where version = '0.6.0') new_v
on conflict do nothing;

-- Everything that was already a normal label, unchanged.
insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
select new_v.id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
from ontology.concept_labels l
join ontology.versions old_v on old_v.id = l.ontology_version_id and old_v.version = '0.5.0'
cross join (select id from ontology.versions where version = '0.6.0') new_v
where not (l.label_type = 'source_term' and l.provenance_type = 'provider')
on conflict do nothing;

-- The provider terms, as alternates. `on conflict do nothing` is what handles
-- `film`, which already exists as a curated alternate on `hub:film_video`.
insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
select new_v.id, l.concept_id, l.label, l.normalized_label, l.locale,
       'alternate', l.provenance_type, l.confidence, l.status, l.external_ref
from ontology.concept_labels l
join ontology.versions old_v on old_v.id = l.ontology_version_id and old_v.version = '0.5.0'
cross join (select id from ontology.versions where version = '0.6.0') new_v
where l.label_type = 'source_term' and l.provenance_type = 'provider'
on conflict (ontology_version_id, concept_id, locale, normalized_label, label_type)
  do nothing;

insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
select new_v.id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
from ontology.concept_edges e
join ontology.versions old_v on old_v.id = e.ontology_version_id and old_v.version = '0.5.0'
cross join (select id from ontology.versions where version = '0.6.0') new_v
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
join ontology.versions old_v on old_v.id = m.ontology_version_id and old_v.version = '0.5.0'
cross join (select id from ontology.versions where version = '0.6.0') new_v
on conflict do nothing;

-- **Assert the thing this migration exists for**, rather than trusting the
-- statements above: every provider term must now be a kind the resolver
-- auto-accepts, or a YouTube run produces candidates and no evidence.
do $$
declare
  version_id uuid;
  not_acceptable integer;
  provider_labels integer;
begin
  select id into version_id from ontology.versions where version = '0.6.0';

  select count(*) into not_acceptable
  from ontology.concept_labels
  where ontology_version_id = version_id
    and provenance_type = 'provider'
    and label_type not in ('preferred', 'alternate');
  if not_acceptable <> 0 then
    raise exception '% provider labels are still not auto-acceptable', not_acceptable;
  end if;

  select count(*) into provider_labels
  from ontology.concept_labels
  where ontology_version_id = version_id and provenance_type = 'provider';
  -- **Twenty, and the first draft of this assertion said nineteen.** `Film`
  -- normalizes to `film`, which `hub:film_video` already carries as a curated
  -- alternate, so a fold looked inevitable — but the unique key includes
  -- `locale`, the provider labels are `und` and the curated one is `en`, and
  -- the two coexist. Harmless: `resolve_alias` groups matches by *concept*, so
  -- two labels reaching `hub:film_video` still auto-accept it once.
  --
  -- Kept as an exact count rather than relaxed to `>= 19`, because the failure
  -- this guards against is labels silently going missing, and a range would
  -- hide exactly that.
  if provider_labels <> 20 then
    raise exception 'expected 20 provider labels, found %', provider_labels;
  end if;
end
$$;

update ontology.versions set status = 'retired'
 where version = '0.5.0' and status = 'published';

update ontology.versions set status = 'published', published_at = now()
 where version = '0.6.0';

commit;
