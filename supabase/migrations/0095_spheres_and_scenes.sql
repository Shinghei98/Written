-- 0095 — the language sphere, and the decade crossed with it. Ontology 0.8.0.
--
-- **A decade is not a taste on its own.** On the owner's library `era:1970s`
-- rested on ABBA, Stevie Wonder, Frankie Kao's 姑娘的酒渦 and Fritz Kreisler —
-- anglophone pop, Mandopop and a violin recital, three unrelated worlds inside
-- one assertion at 0.403. 1970s British pop and 1970s Cantopop are not the same
-- fact about a person, and an era that cannot tell them apart says almost
-- nothing. The owner's words: *"eras strongly interact with language sphere"*.
--
-- Two families of concept, and the second is the point of the first.
--
-- **`sphere:*` — five language spheres.** Apple's own taxonomy names four of
-- them (`Cantopop`, `Mandopop`, `J-Pop`, `K-Pop`), so those are reads. It has
-- no genre meaning "English-language" because in that taxonomy the anglophone
-- market is the *unmarked* case — `Pop`, `Rock`, `R&B/Soul` — while everything
-- else is marked. `sphere:anglophone` therefore rests on a convention rather
-- than a stated field, which is why `Latin` is deliberately excluded from it in
-- `GENRE_SPHERES` rather than swept in as unmarked.
--
-- **`scene:*` — six decades × five spheres.** Named `scene` rather than
-- `era_sphere` because it is a thing a sentence can be about, which is this
-- product's whole surface: *"you're both into the 1970s Mandarin scene"*. A
-- decade alone and a language alone are axes; their intersection is a place.
--
-- **Classical periods are not crossed with anything.** Baroque music is baroque
-- in every language, so `scene:baroque_anglophone` would describe nothing and
-- would compete with `era:baroque` for the same evidence. The cross-product is
-- decades only, which is why it is 30 and not 65.
--
-- **The whole cross-product is minted, not only the pairs this library
-- produces.** These are authored vocabulary from a closed list, not terms mined
-- from anybody's data, so `EmergentTermMiner`'s five-user floor does not apply
-- and cannot: that floor exists to stop one person's private string becoming a
-- public concept, and `scene:1980s_korean` is neither private nor anybody's.
-- Minting on demand would also mean the concept set differed per install.

begin;

insert into ontology.versions (id, version, parent_version_id, status, description, published_at)
select gen_random_uuid(), '0.8.0', v.id, 'draft',
       'Language spheres, and decades crossed with them.', null
from ontology.versions v where v.version = '0.7.0'
on conflict (version) do nothing;

insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
select new_v.id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
from ontology.concept_revisions r
join ontology.versions old_v on old_v.id = r.ontology_version_id and old_v.version = '0.7.0'
cross join (select id from ontology.versions where version = '0.8.0') new_v
on conflict do nothing;

insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
select new_v.id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
from ontology.concept_labels l
join ontology.versions old_v on old_v.id = l.ontology_version_id and old_v.version = '0.7.0'
cross join (select id from ontology.versions where version = '0.8.0') new_v
on conflict do nothing;

insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
select new_v.id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
from ontology.concept_edges e
join ontology.versions old_v on old_v.id = e.ontology_version_id and old_v.version = '0.7.0'
cross join (select id from ontology.versions where version = '0.8.0') new_v
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
join ontology.versions old_v on old_v.id = m.ontology_version_id and old_v.version = '0.7.0'
cross join (select id from ontology.versions where version = '0.8.0') new_v
on conflict do nothing;

-- The five spheres. `concept_kind` is `topic`, matching `era:*` — both are
-- properties of a work rather than things somebody made, which is what
-- `creator` means here.
create temporary table new_sphere (concept_key text primary key, label text)
  on commit drop;
insert into new_sphere values
  ('sphere:anglophone', 'English-language music'),
  ('sphere:cantonese',  'Cantonese-language music'),
  ('sphere:mandarin',   'Mandarin-language music'),
  ('sphere:japanese',   'Japanese-language music'),
  ('sphere:korean',     'Korean-language music');

-- The cross-product, generated rather than typed: thirty hand-written rows is
-- thirty chances to write `scene:2010s_mandrin`, and the two lists are the
-- authority.
create temporary table new_scene (concept_key text primary key, label text)
  on commit drop;
insert into new_scene
select 'scene:' || d.decade || '_' || s.sphere,
       d.pretty || ' ' || s.pretty
from (values ('1970s','1970s'), ('1980s','1980s'), ('1990s','1990s'),
             ('2000s','2000s'), ('2010s','2010s'), ('2020s','2020s'))
       as d(decade, pretty)
cross join (values ('anglophone','English-language'), ('cantonese','Cantonese'),
                   ('mandarin','Mandarin'), ('japanese','Japanese'),
                   ('korean','Korean'))
       as s(sphere, pretty);

insert into ontology.concepts (id, concept_key)
select gen_random_uuid(), concept_key from new_sphere
union all select gen_random_uuid(), concept_key from new_scene
on conflict (concept_key) do nothing;

insert into ontology.concept_revisions (
  ontology_version_id, concept_id, preferred_label, concept_kind,
  definition, sensitivity, inference_policy, status, metadata)
-- **`review_required`, not `inferable`, and that is a decision rather than
-- caution.** The precedent is `0077`, where every sport is `review_required`
-- because a fitness activity implies something about somebody's body. A
-- language sphere is the same shape one axis over: *"listens to Cantopop"* is a
-- music preference, and *"belongs to the Cantonese-language sphere"* is one
-- step from a claim about where somebody is from. Nothing new is exposed —
-- `genre:cantopop` already exists and is already asserted — but the sphere
-- groups those genres under a name that reads as an origin, and the surface
-- that eventually shows it should have to ask.
--
-- Scenes inherit the same policy despite being anchored to a decade, because a
-- scene is `broader` than its sphere and a looser policy on the child would let
-- the stricter parent be reached around.
select v.id, c.id, n.label, 'topic', null, 'ordinary', 'review_required', 'active', '{}'::jsonb
from (select concept_key, label from new_sphere
      union all select concept_key, label from new_scene) n
join ontology.concepts c on c.concept_key = n.concept_key
cross join (select id from ontology.versions where version = '0.8.0') v
on conflict (ontology_version_id, concept_id) do nothing;

insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status)
select v.id, c.id, n.label, lower(n.label), 'en', 'preferred', 'curated', 1.0, 'active'
from (select concept_key, label from new_sphere
      union all select concept_key, label from new_scene) n
join ontology.concepts c on c.concept_key = n.concept_key
cross join (select id from ontology.versions where version = '0.8.0') v
on conflict (ontology_version_id, concept_id, locale, normalized_label, label_type)
  do nothing;

-- **Every scene is `broader` than both of its parts.** That is what makes the
-- composite navigable rather than a flat string: a reader asking what
-- `scene:1970s_mandarin` is under gets the decade and the language, and the
-- graph can roll a scene up to either axis without parsing its name.
insert into ontology.concept_edges (
  ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
  confidence, provenance_type, provenance, status)
select v.id, child.id, 'broader', parent.id, 1.0, 'curated',
       '{"source": "0095"}'::jsonb, 'active'
from new_scene n
join ontology.concepts child on child.concept_key = n.concept_key
cross join lateral (values
    ('era:'    || split_part(replace(n.concept_key, 'scene:', ''), '_', 1)),
    ('sphere:' || split_part(replace(n.concept_key, 'scene:', ''), '_', 2))
  ) as p(parent_key)
join ontology.concepts parent on parent.concept_key = p.parent_key
cross join (select id from ontology.versions where version = '0.8.0') v
on conflict do nothing;

do $$
declare
  spheres integer;
  scenes integer;
  edges integer;
begin
  select count(*) into spheres
  from ontology.concept_revisions r
  join ontology.concepts c on c.id = r.concept_id
  join ontology.versions v on v.id = r.ontology_version_id and v.version = '0.8.0'
  where c.concept_key like 'sphere:%';

  select count(*) into scenes
  from ontology.concept_revisions r
  join ontology.concepts c on c.id = r.concept_id
  join ontology.versions v on v.id = r.ontology_version_id and v.version = '0.8.0'
  where c.concept_key like 'scene:%';

  -- Two per scene, and this is the assertion that matters: the edge insert
  -- parses each scene's own name to find its parents, so a sphere whose key
  -- contains an underscore would split wrongly and silently produce one edge
  -- instead of two. None does today; this is what notices if one ever does.
  select count(*) into edges
  from ontology.concept_edges e
  join ontology.concepts c on c.id = e.subject_concept_id
  join ontology.versions v on v.id = e.ontology_version_id and v.version = '0.8.0'
  where c.concept_key like 'scene:%' and e.predicate_key = 'broader';

  if spheres <> 5 then raise exception 'expected 5 spheres, found %', spheres; end if;
  if scenes <> 30 then raise exception 'expected 30 scenes, found %', scenes; end if;
  if edges <> 60 then raise exception 'expected 60 scene edges, found %', edges; end if;
end
$$;

update ontology.versions set status = 'retired'
 where version = '0.7.0' and status = 'published';

update ontology.versions set status = 'published', published_at = now()
 where version = '0.8.0';

commit;
