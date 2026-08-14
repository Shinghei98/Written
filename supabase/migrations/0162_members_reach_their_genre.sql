-- 0162 — a member belongs to their group's genre, and a pianist to his.
--
-- **The Music block was the fallback doing its job and the vocabulary not doing
-- its own.** Eight terms reached no genre at all, so `concept_block` fell back
-- to `hub:music` and the page read "Music" over six K-pop idols, a musical
-- performer and a Japanese pianist — which is exactly the coarseness `0154`
-- replaced everywhere else.
--
-- Six are members rather than groups: Kim Chaewon and Kazuha of LE SSERAFIM,
-- Ahyeon, Asa, Chiquita and Ruka of BABYMONSTER. `0146`'s hashtag lane is what
-- surfaced them — `#kimchaewon` and `#kazuha` are among the commonest tags on
-- this account — and nothing had ever said what they are.
--
-- Cynthia Erivo reaches only `genre:soundtrack`, and her evidence here is
-- Wicked, so she belongs with the musicals. marasy8 is a Japanese pianist whose
-- library sits with J-Pop.
--
-- **These are edges about the world, not about one person.** A member being in
-- a genre is true whoever is listening, which is why it belongs in the ontology
-- rather than in anybody's assertions.

begin;

insert into ontology.versions (id, version, parent_version_id, status, description, published_at)
select gen_random_uuid(), '0.20.0', v.id, 'draft',
       'Members reach their genre, so Music stops being a catch-all.', null
from ontology.versions v where v.version = '0.19.0'
on conflict (version) do nothing;

insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
select new_v.id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
from ontology.concept_revisions r
join ontology.versions old_v on old_v.id = r.ontology_version_id and old_v.version = '0.19.0'
cross join (select id from ontology.versions where version = '0.20.0') new_v
on conflict do nothing;

insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
select new_v.id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
from ontology.concept_labels l
join ontology.versions old_v on old_v.id = l.ontology_version_id and old_v.version = '0.19.0'
cross join (select id from ontology.versions where version = '0.20.0') new_v
on conflict do nothing;

insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
select new_v.id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
from ontology.concept_edges e
join ontology.versions old_v on old_v.id = e.ontology_version_id and old_v.version = '0.19.0'
cross join (select id from ontology.versions where version = '0.20.0') new_v
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
join ontology.versions old_v on old_v.id = m.ontology_version_id and old_v.version = '0.19.0'
cross join (select id from ontology.versions where version = '0.20.0') new_v
on conflict do nothing;

create temporary table seed_member (subject_key text, object_key text) on commit drop;
insert into seed_member values
  ('creator:kim_chaewon', 'genre:k_pop'),
  ('creator:kazuha', 'genre:k_pop'),
  ('creator:ahyeon', 'genre:k_pop'),
  ('creator:asa', 'genre:k_pop'),
  ('creator:chiquita', 'genre:k_pop'),
  ('creator:ruka', 'genre:k_pop'),
  ('creator:cynthia_erivo', 'genre:musicals'),
  ('creator:marasy8', 'genre:j_pop');

insert into ontology.concept_edges (
  ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
  confidence, provenance_type, provenance, status)
select v.id, s.id, 'broader', o.id, 1.0, 'curated', '{"source": "0162"}'::jsonb, 'active'
from seed_member m
join ontology.concepts s on s.concept_key = m.subject_key
join ontology.concepts o on o.concept_key = m.object_key
cross join (select id from ontology.versions where version = '0.20.0') v
on conflict do nothing;

update ontology.versions set status = 'retired'
 where version = '0.19.0' and status = 'published';

update ontology.versions set status = 'published', published_at = now()
 where version = '0.20.0';

do $$
declare
  v_id uuid;
  answer text;
  edges integer;
  enqueued integer;
begin
  select id into v_id from ontology.versions where status = 'published';

  select count(*) into edges
  from ontology.concept_edges e
  join ontology.concepts s on s.id = e.subject_concept_id
  where e.ontology_version_id = v_id and e.predicate_key = 'broader'
    and s.concept_key in ('creator:kim_chaewon', 'creator:kazuha', 'creator:ahyeon',
      'creator:asa', 'creator:chiquita', 'creator:ruka', 'creator:cynthia_erivo',
      'creator:marasy8');
  if edges < 8 then
    raise exception 'expected 8 member edges, found %', edges;
  end if;

  select semantic_private.concept_block(c.id, v_id) into answer
  from ontology.concepts c where c.concept_key = 'creator:kim_chaewon';
  if answer is distinct from 'genre:k_pop' then
    raise exception 'Kim Chaewon blocks as % rather than K-Pop', answer;
  end if;

  select semantic_private.concept_block(c.id, v_id) into answer
  from ontology.concepts c where c.concept_key = 'creator:marasy8';
  if answer is distinct from 'genre:j_pop' then
    raise exception 'marasy8 blocks as % rather than J-Pop', answer;
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           'ontology 0.20.0: members reach their genre'
         ) into enqueued;
  raise notice '0162: enqueued % recompute job(s)', enqueued;
end;
$$;

commit;
