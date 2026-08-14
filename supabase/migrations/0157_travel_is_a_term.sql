-- 0157 — travel is a term, and it is not the place.
--
-- **The owner's rule: a place is an affinity unless it is a travel.** `0152`
-- and `0153` minted `place:*` — *where somebody was* — and the page never drew
-- them, correctly: `list_assertions` allows `creator`, `work` and `activity`,
-- and a place is none of those. A place is evidence. `travel:*` is the claim.
--
-- So this mints the family the rule actually asks for, as kind `activity`,
-- which is what a trip is: something somebody did.
--
-- **Minted whole rather than on demand**, which is the standing rule for
-- authored vocabulary — the concept set must not differ per install, and a
-- travel term that appears only once somebody has flown somewhere would make it
-- do exactly that. Thirteen places, thirteen trips, whether or not anybody has
-- taken them.
--
-- ## What this does not do
--
-- **It carries no evidence.** Calendar observations may not enter
-- `observation_mappings` — refused in Python by
-- `ObservationMapper._source_projection_is_valid`, again in the database by
-- `guard_calendar_observation_mapping`, and §7 licenses only the classifier over
-- calendar rows. Nothing here bypasses any of them, and nothing here asserts a
-- trip about anybody.
--
-- The path that will is already visible in the schema:
-- `assertion_has_calendar_evidence` has a second branch matching on
-- `predicate_key in ('recurring_presence_at', 'home_base_candidate')` with no
-- mapping join at all. A calendar assertion is meant to be recognised by its
-- *predicate*, not by evidence rows — which is why no guard needs defeating, and
-- why the remaining work is a writer for those predicates rather than a hole
-- punched in a deny-list.
--
-- ## TRAVEL as a block
--
-- `subject:travel` is the heading, above the individual trips, and it sits ahead
-- of CONTENT CREATORS in the order: a trip is a specific thing somebody did,
-- while "content creators" is what is left when nothing says what a person makes.

begin;

insert into ontology.versions (id, version, parent_version_id, status, description, published_at)
select gen_random_uuid(), '0.19.0', v.id, 'draft',
       'Travel is a term of its own, distinct from the place.', null
from ontology.versions v where v.version = '0.18.0'
on conflict (version) do nothing;

insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
select new_v.id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
from ontology.concept_revisions r
join ontology.versions old_v on old_v.id = r.ontology_version_id and old_v.version = '0.18.0'
cross join (select id from ontology.versions where version = '0.19.0') new_v
on conflict do nothing;

insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
select new_v.id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
from ontology.concept_labels l
join ontology.versions old_v on old_v.id = l.ontology_version_id and old_v.version = '0.18.0'
cross join (select id from ontology.versions where version = '0.19.0') new_v
on conflict do nothing;

insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
select new_v.id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
from ontology.concept_edges e
join ontology.versions old_v on old_v.id = e.ontology_version_id and old_v.version = '0.18.0'
cross join (select id from ontology.versions where version = '0.19.0') new_v
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
join ontology.versions old_v on old_v.id = m.ontology_version_id and old_v.version = '0.18.0'
cross join (select id from ontology.versions where version = '0.19.0') new_v
on conflict do nothing;

insert into ontology.concepts (id, concept_key)
values (gen_random_uuid(), 'subject:travel')
on conflict (concept_key) do nothing;

insert into ontology.concept_revisions (
  ontology_version_id, concept_id, preferred_label, concept_kind,
  sensitivity, inference_policy, status)
select v.id, c.id, 'Travel', 'topic', 'ordinary', 'review_required', 'active'
from ontology.concepts c
cross join (select id from ontology.versions where version = '0.19.0') v
where c.concept_key = 'subject:travel'
on conflict do nothing;

insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status, external_ref)
select v.id, c.id, 'Travel', 'travel', 'en', 'preferred', 'curated', 1.0, 'active', '{}'::jsonb
from ontology.concepts c
cross join (select id from ontology.versions where version = '0.19.0') v
where c.concept_key = 'subject:travel'
on conflict do nothing;

-- One trip per place we can recognise. `activity`, because a trip is something
-- somebody did — and because that is a kind the page is allowed to draw.
create temporary table seed_travel (travel_key text primary key, place_key text not null, label text not null) on commit drop;
insert into seed_travel values
  ('travel:cancun', 'place:cancun', 'Trip to Cancún'),
  ('travel:hong_kong', 'place:hong_kong', 'Trip to Hong Kong'),
  ('travel:saint_louis', 'place:saint_louis', 'Trip to St. Louis'),
  ('travel:los_angeles', 'place:los_angeles', 'Trip to Los Angeles'),
  ('travel:new_york', 'place:new_york', 'Trip to New York'),
  ('travel:san_francisco', 'place:san_francisco', 'Trip to San Francisco'),
  ('travel:chicago', 'place:chicago', 'Trip to Chicago'),
  ('travel:seattle', 'place:seattle', 'Trip to Seattle'),
  ('travel:london', 'place:london', 'Trip to London'),
  ('travel:paris', 'place:paris', 'Trip to Paris'),
  ('travel:tokyo', 'place:tokyo', 'Trip to Tokyo'),
  ('travel:singapore', 'place:singapore', 'Trip to Singapore'),
  ('travel:taipei', 'place:taipei', 'Trip to Taipei');

insert into ontology.concepts (id, concept_key)
select gen_random_uuid(), t.travel_key from seed_travel t
on conflict (concept_key) do nothing;

insert into ontology.concept_revisions (
  ontology_version_id, concept_id, preferred_label, concept_kind,
  sensitivity, inference_policy, status)
select v.id, c.id, t.label, 'activity', 'ordinary', 'review_required', 'active'
from seed_travel t
join ontology.concepts c on c.concept_key = t.travel_key
cross join (select id from ontology.versions where version = '0.19.0') v
on conflict do nothing;

insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status, external_ref)
select v.id, c.id, t.label, lower(t.label), 'en', 'preferred', 'curated', 1.0, 'active', '{}'::jsonb
from seed_travel t
join ontology.concepts c on c.concept_key = t.travel_key
cross join (select id from ontology.versions where version = '0.19.0') v
on conflict do nothing;

-- Every trip under the TRAVEL heading, and the heading under the places hub.
insert into ontology.concept_edges (
  ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
  confidence, provenance_type, provenance, status)
select v.id, c.id, 'broader', parent.id, 1.0, 'curated', '{"source": "0157"}'::jsonb, 'active'
from seed_travel t
join ontology.concepts c on c.concept_key = t.travel_key
join ontology.concepts parent on parent.concept_key = 'subject:travel'
cross join (select id from ontology.versions where version = '0.19.0') v
on conflict do nothing;

insert into ontology.concept_edges (
  ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
  confidence, provenance_type, provenance, status)
select v.id, c.id, 'broader', parent.id, 1.0, 'curated', '{"source": "0157"}'::jsonb, 'active'
from ontology.concepts c
join ontology.concepts parent on parent.concept_key = 'hub:places_cultures'
cross join (select id from ontology.versions where version = '0.19.0') v
where c.concept_key = 'subject:travel'
on conflict do nothing;

update ontology.versions set status = 'retired'
 where version = '0.18.0' and status = 'published';

update ontology.versions set status = 'published', published_at = now()
 where version = '0.19.0';

-- TRAVEL joins the block set ahead of CONTENT CREATORS: a trip is a specific
-- thing somebody did, while a content creator is what is left when nothing says
-- what a person makes.
create or replace function semantic_private.concept_block(
  target_concept_id uuid, target_version_id uuid
) returns text
language sql
stable
set search_path to ''
as $function$
  with recursive blocks(block_key, priority) as (
    values
      ('genre:anime', 1), ('genre:classical', 2), ('genre:musicals', 3),
      ('genre:k_pop', 4), ('genre:j_pop', 5), ('genre:mandopop', 6),
      ('genre:cantopop', 7), ('genre:video_game', 8), ('subject:science', 9),
      ('subject:language_learning', 10), ('hub:news_current_affairs', 11),
      ('subject:travel', 12), ('subject:content_creators', 13)
  ),
  climb(concept_id, depth) as (
    select target_concept_id, 0
    union all
    select edge.object_concept_id, climb.depth + 1
    from climb
    join ontology.concept_edges edge
      on edge.subject_concept_id = climb.concept_id
     and edge.predicate_key = 'broader'
     and edge.ontology_version_id = target_version_id
     and edge.status = 'active'
    where climb.depth < 8
  )
  select coalesce(
    (select c.concept_key
       from climb
       join ontology.concepts c on c.id = climb.concept_id
       join blocks b on b.block_key = c.concept_key
      order by b.priority, climb.depth, c.concept_key
      limit 1),
    (select c.concept_key
       from climb
       join ontology.concepts c on c.id = climb.concept_id
      where c.concept_key like 'hub:%'
      order by climb.depth, c.concept_key
      limit 1)
  );
$function$;

do $$
declare
  v_id uuid;
  answer text;
  kind text;
  enqueued integer;
begin
  select id into v_id from ontology.versions where status = 'published';

  select semantic_private.concept_block(c.id, v_id) into answer
  from ontology.concepts c where c.concept_key = 'travel:cancun';
  if answer is distinct from 'subject:travel' then
    raise exception 'travel:cancun blocks as % rather than travel', answer;
  end if;

  -- **The kind is what lets the page draw it at all.** `list_assertions` allows
  -- creator, work and activity; `place` is why `0152`'s places were invisible.
  select r.concept_kind into kind
  from ontology.concepts c
  join ontology.concept_revisions r on r.concept_id = c.id and r.ontology_version_id = v_id
  where c.concept_key = 'travel:cancun';
  if kind is distinct from 'activity' then
    raise exception 'travel:cancun is kind % and would be withheld', kind;
  end if;

  -- The earlier blocks must be untouched by the reordering.
  select semantic_private.concept_block(c.id, v_id) into answer
  from ontology.concepts c where c.concept_key = 'creator:kripparrian';
  if answer is distinct from 'subject:content_creators' then
    raise exception 'Kripparrian moved to %', answer;
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           'ontology 0.19.0: travel is a term of its own'
         ) into enqueued;
  raise notice '0157: travel minted, % recompute job(s)', enqueued;
end;
$$;

commit;
