-- 0091 — nine artists were one concept.
--
-- **`creator:unnamed` was a merge, not a junk label.** Its nine aliases are
-- eight Korean performers — 김도연, 류정한, 서정아, 심은지, 용배, 이기, 이동혁,
-- 전동석 — and one decorative-Unicode name, every one of them carrying the
-- others' work. An assertion was standing on it.
--
-- The cause was one line in `tools/seed_music_from_library.py`, fixed in the
-- same change as this: `unicodedata.normalize("NFKD")` decomposes a Hangul
-- syllable into jamo — 류 becomes ᄅ + ᅲ — while the key's character class
-- accepts only precomposed syllables `가-힯`. Every Korean name stripped to
-- empty and fell through to a *constant* fallback, so they all landed on one
-- key. Two bugs compounding: the decomposition, and a fallback that could
-- collide.
--
-- **This splits them; it does not rewrite history.** The old concept keeps its
-- id and its mappings — those rows recorded what the resolver actually did on
-- the day, and `raw_source_records` is append-only for the same reason. What
-- changes is what the *current* ontology says: nine correct concepts exist,
-- `creator:unnamed` is deprecated with its labels withheld so nothing can
-- resolve to it again, and the assertion resting on it is retired.
--
-- **Retiring the assertion is the point of the migration.** Leaving it would
-- keep a claim that this person has an affinity to a concept which is eight
-- different people — the "wrong merge attributes one person's work to another"
-- failure `music_dictionary.py` warns about, standing as a live claim.
-- `machine_state = 'inactive'` is the honest state: collected, and struck off.

begin;

insert into ontology.versions (id, version, parent_version_id, status, description, published_at)
select gen_random_uuid(), '0.7.0', v.id, 'draft',
       'Split creator:unnamed into the nine artists it had merged.', null
from ontology.versions v where v.version = '0.6.0'
on conflict (version) do nothing;

insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
select new_v.id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
from ontology.concept_revisions r
join ontology.versions old_v on old_v.id = r.ontology_version_id and old_v.version = '0.6.0'
cross join (select id from ontology.versions where version = '0.7.0') new_v
on conflict do nothing;

-- **Every label except the merged concept's.** Copying them forward would leave
-- nine names still resolving to one concept, which is the whole defect.
insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
select new_v.id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
from ontology.concept_labels l
join ontology.versions old_v on old_v.id = l.ontology_version_id and old_v.version = '0.6.0'
join ontology.concepts c on c.id = l.concept_id
cross join (select id from ontology.versions where version = '0.7.0') new_v
where c.concept_key <> 'creator:unnamed'
on conflict do nothing;

insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
select new_v.id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
from ontology.concept_edges e
join ontology.versions old_v on old_v.id = e.ontology_version_id and old_v.version = '0.6.0'
cross join (select id from ontology.versions where version = '0.7.0') new_v
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
join ontology.versions old_v on old_v.id = m.ontology_version_id and old_v.version = '0.6.0'
cross join (select id from ontology.versions where version = '0.7.0') new_v
on conflict do nothing;

create temporary table split_creator (concept_key text primary key, label text, normalized text) on commit drop;
insert into split_creator values
  ('creator:김도연', '김도연', '김도연'),
  ('creator:류정한', '류정한', '류정한'),
  ('creator:서정아', '서정아', '서정아'),
  ('creator:심은지', '심은지', '심은지'),
  ('creator:용배', '용배', '용배'),
  ('creator:이기', '이기', '이기'),
  ('creator:이동혁', '이동혁', '이동혁'),
  ('creator:전동석', '전동석', '전동석'),
  ('creator:xc9521d1da1aa', 'ꉈꀧ꒒꒒ꁄꍈꍈꀧ꒦ꉈ ꉣꅔꎡꅔꁕꁄ', 'ꉈꀧ꒒꒒ꁄꍈꍈꀧ꒦ꉈ ꉣꅔꎡꅔꁕꁄ');

insert into ontology.concepts (id, concept_key)
select gen_random_uuid(), s.concept_key from split_creator s
on conflict (concept_key) do nothing;

insert into ontology.concept_revisions (
  ontology_version_id, concept_id, preferred_label, concept_kind,
  definition, sensitivity, inference_policy, status, metadata)
select v.id, c.id, s.label, 'creator',
       'Split from creator:unnamed, which merged nine artists.',
       'ordinary', 'inferable', 'active', '{}'::jsonb
from split_creator s
join ontology.concepts c on c.concept_key = s.concept_key
cross join (select id from ontology.versions where version = '0.7.0') v
on conflict (ontology_version_id, concept_id) do nothing;

insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status)
select v.id, c.id, s.label, s.normalized, 'und',
       'preferred', 'curated', 1.0, 'active'
from split_creator s
join ontology.concepts c on c.concept_key = s.concept_key
cross join (select id from ontology.versions where version = '0.7.0') v
on conflict (ontology_version_id, concept_id, locale, normalized_label, label_type)
  do nothing;

-- Deprecated rather than deleted: `observation_mappings` still points at it and
-- those rows are a record of what the resolver did, not a claim that stands.
update ontology.concept_revisions r
set status = 'deprecated'
from ontology.concepts c, ontology.versions v
where c.id = r.concept_id and v.id = r.ontology_version_id
  and c.concept_key = 'creator:unnamed' and v.version = '0.7.0';

-- The claim resting on the merge is struck off. "Collected then struck off" and
-- "never collected" are different facts, which is why this is `inactive` and
-- not a delete.
update semantic_private.user_assertions a
set machine_state = 'inactive', updated_at = now()
from ontology.concepts c
where c.id = a.concept_id and c.concept_key = 'creator:unnamed';

do $$
declare
  version_id uuid;
  leaked integer;
  split integer;
begin
  select id into version_id from ontology.versions where version = '0.7.0';

  -- Nothing may resolve to the merged concept any more.
  select count(*) into leaked
  from ontology.concept_labels l
  join ontology.concepts c on c.id = l.concept_id
  where l.ontology_version_id = version_id and c.concept_key = 'creator:unnamed';
  if leaked <> 0 then
    raise exception 'the merged concept still carries % labels', leaked;
  end if;

  select count(*) into split
  from ontology.concept_revisions r
  join ontology.concepts c on c.id = r.concept_id
  where r.ontology_version_id = version_id
    and r.definition = 'Split from creator:unnamed, which merged nine artists.';
  if split <> 9 then
    raise exception 'expected 9 split concepts, found %', split;
  end if;

  if exists (
    select 1 from semantic_private.user_assertions a
    join ontology.concepts c on c.id = a.concept_id
    where c.concept_key = 'creator:unnamed' and a.machine_state <> 'inactive') then
    raise exception 'an assertion still stands on the merged concept';
  end if;
end
$$;

update ontology.versions set status = 'retired'
 where version = '0.6.0' and status = 'published';
update ontology.versions set status = 'published', published_at = now()
 where version = '0.7.0';

commit;
