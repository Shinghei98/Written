-- 0154 — blocks become the terms people recognise, not the drawers above them.
--
-- **`0145` filed every term under one of thirteen hubs, and the owner's reading
-- is that a hub is too coarse to mean anything.** Bach, LE SSERAFIM, Ayase and
-- Jay Chou all read as "Music"; Kripparrian, Asmongold and PewDiePie read as
-- "Games & play" — which the owner rejected outright: **games are games, like
-- Hearthstone or VALORANT, and those three are content creators.**
--
-- So a block is now the finer parent: CLASSICAL, K-POP, J-POP, MANDOPOP,
-- CANTOPOP, MUSICAL, ANIME, GAMES, SCIENCE, LANGUAGE, NEWS and CONTENT
-- CREATORS. The hub survives as the fallback, so a term reaching no block still
-- lands somewhere honest rather than in "Other".
--
-- ## The set is authored, and it has to be
--
-- `hub:*` could be found by kind. This cannot: SCIENCE and LANGUAGE are
-- `subject:*`, the music blocks are `genre:*`, NEWS is still a hub, and CONTENT
-- CREATORS is minted here. The twelve are a judgement about what a person
-- recognises about themselves, so they are listed rather than derived.
--
-- **Priority, because `broader` is a DAG and a term reaches several.** Ayase is
-- both J-POP and ANIME; a K-pop soloist is both K-POP and a creator. The owner
-- set the order and it is encoded below: the most specific claim wins, and
-- CONTENT CREATORS sits last precisely because it is what is left when nothing
-- says what somebody makes.
--
-- ## What moves, and why each one
--
-- - **The six creators leave their hubs.** Kripparrian, Asmongold and PewDiePie
--   were `broader hub:games_play`, which is what made "Games & play" a block
--   full of people rather than games. Onion Man, HowFun and 反正我很閒 were
--   `hub:film_video`. All six become CONTENT CREATORS.
-- - **GAMES is keyed on `genre:video_game`, and its parent was wrong.** It was
--   `broader hub:music` — a video game filed under Music, inherited from the
--   Apple Music genre vocabulary where the rows are soundtracks. As a *parent*
--   that is simply false, and it would have put every game in the Music block.
--   It becomes `hub:games_play` and its label becomes `Games`.
-- - **Six science channels and one language channel gain a subject**, which is
--   what moves them out of the undifferentiated "Books, ideas & learning".
-- - **Three K-pop terms and two musicals gain the parent they lacked** — JO YURI
--   reached only `genre:pop_rock`, and both musicals only `genre:soundtrack`.
--
-- The four channels `0145` left unparented stay unparented. They are YouTube
-- channels and would fit CONTENT CREATORS trivially — and that is the argument
-- against it: filing them there would say we know what they are because we know
-- where they were published, which is the platform, not the person.

begin;

insert into ontology.versions (id, version, parent_version_id, status, description, published_at)
select gen_random_uuid(), '0.18.0', v.id, 'draft',
       'Blocks are the finer parent: twelve of them, hub as fallback.', null
from ontology.versions v where v.version = '0.17.0'
on conflict (version) do nothing;

insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
select new_v.id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
from ontology.concept_revisions r
join ontology.versions old_v on old_v.id = r.ontology_version_id and old_v.version = '0.17.0'
cross join (select id from ontology.versions where version = '0.18.0') new_v
on conflict do nothing;

insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
select new_v.id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
from ontology.concept_labels l
join ontology.versions old_v on old_v.id = l.ontology_version_id and old_v.version = '0.17.0'
cross join (select id from ontology.versions where version = '0.18.0') new_v
on conflict do nothing;

insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
select new_v.id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
from ontology.concept_edges e
join ontology.versions old_v on old_v.id = e.ontology_version_id and old_v.version = '0.17.0'
cross join (select id from ontology.versions where version = '0.18.0') new_v
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
join ontology.versions old_v on old_v.id = m.ontology_version_id and old_v.version = '0.17.0'
cross join (select id from ontology.versions where version = '0.18.0') new_v
on conflict do nothing;

-- CONTENT CREATORS: one block, because the owner merged streamers and YouTubers.
-- The platform somebody publishes on is not what they are about, and splitting
-- by it was filing people by their distribution channel.
insert into ontology.concepts (id, concept_key)
values (gen_random_uuid(), 'subject:content_creators')
on conflict (concept_key) do nothing;

insert into ontology.concept_revisions (
  ontology_version_id, concept_id, preferred_label, concept_kind,
  sensitivity, inference_policy, status)
select v.id, c.id, 'Content creators', 'topic', 'ordinary', 'inferable', 'active'
from ontology.concepts c
cross join (select id from ontology.versions where version = '0.18.0') v
where c.concept_key = 'subject:content_creators'
on conflict do nothing;

insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status, external_ref)
select v.id, c.id, 'Content creators', 'content creators', 'en',
       'preferred', 'curated', 1.0, 'active', '{}'::jsonb
from ontology.concepts c
cross join (select id from ontology.versions where version = '0.18.0') v
where c.concept_key = 'subject:content_creators'
on conflict do nothing;

-- `Video Game` reads as a genre; as a block heading it is `Games`.
update ontology.concept_revisions r
   set preferred_label = 'Games'
  from ontology.concepts c, ontology.versions v
 where r.concept_id = c.id and c.concept_key = 'genre:video_game'
   and r.ontology_version_id = v.id and v.version = '0.18.0';

-- A game is not music. This edge came from the Apple Music genre vocabulary,
-- where the rows are soundtracks, and as a parent it would have put every game
-- in the Music block.
delete from ontology.concept_edges e
 using ontology.concepts subject, ontology.concepts object, ontology.versions v
 where e.subject_concept_id = subject.id and subject.concept_key = 'genre:video_game'
   and e.object_concept_id = object.id and object.concept_key = 'hub:music'
   and e.ontology_version_id = v.id and v.version = '0.18.0'
   and e.predicate_key = 'broader';

create temporary table seed_block_edge (subject_key text, object_key text) on commit drop;
insert into seed_block_edge values
  ('genre:video_game', 'hub:games_play'),
  -- The six the owner named: creators, not games and not films.
  ('creator:kripparrian', 'subject:content_creators'),
  ('creator:asmongold', 'subject:content_creators'),
  ('creator:pewdiepie', 'subject:content_creators'),
  ('creator:onion_man', 'subject:content_creators'),
  ('creator:howfun', 'subject:content_creators'),
  ('creator:fanzheng_wo_hen_xian', 'subject:content_creators'),
  -- Science, which is what separates them from an undifferentiated shelf.
  ('creator:statquest', 'subject:science'),
  ('creator:professor_dave_explains', 'subject:science'),
  ('creator:ritvikmath', 'subject:science'),
  ('creator:steve_brunton', 'subject:science'),
  ('creator:medicosis_perfectionalis', 'subject:science'),
  ('creator:pansci', 'subject:science'),
  ('creator:learn_french_with_alexa', 'subject:language_learning'),
  -- Terms that reached no music genre at all.
  ('creator:jo_yuri', 'genre:k_pop'),
  ('creator:jyp_entertainment', 'genre:k_pop'),
  ('creator:channel_miyawaki_sakura', 'genre:k_pop'),
  ('work:wicked', 'genre:musicals'),
  ('work:footloose_the_musical', 'genre:musicals');

insert into ontology.concept_edges (
  ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
  confidence, provenance_type, provenance, status)
select v.id, s.id, 'broader', o.id, 1.0, 'curated', '{"source": "0154"}'::jsonb, 'active'
from seed_block_edge e
join ontology.concepts s on s.concept_key = e.subject_key
join ontology.concepts o on o.concept_key = e.object_key
cross join (select id from ontology.versions where version = '0.18.0') v
on conflict do nothing;

update ontology.versions set status = 'retired'
 where version = '0.17.0' and status = 'published';

update ontology.versions set status = 'published', published_at = now()
 where version = '0.18.0';

-- **The block is now the nearest *authored* block, by priority then depth.**
--
-- `0145` walked to the nearest `hub:*`. This walks the same DAG and stops at the
-- first member of the twelve, falling back to the hub when a term reaches none —
-- so nothing that had a block loses one, and a term with a finer parent gains a
-- better heading.
--
-- Depth-bounded for `0145`'s reason: `broader` is not guaranteed acyclic by any
-- constraint, and this runs once per row on every Memories load.
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
      ('subject:content_creators', 12)
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
    -- An authored block, most specific first.
    (select c.concept_key
       from climb
       join ontology.concepts c on c.id = climb.concept_id
       join blocks b on b.block_key = c.concept_key
      order by b.priority, climb.depth, c.concept_key
      limit 1),
    -- Otherwise the drawer above it, which is `0145`'s answer unchanged.
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
begin
  select id into v_id from ontology.versions where status = 'published';

  -- **Called, not read.** A check on a function's text is not a check on its
  -- behaviour, and this one has to be right for four different shapes.
  select semantic_private.concept_block(c.id, v_id) into answer
  from ontology.concepts c where c.concept_key = 'creator:kripparrian';
  if answer is distinct from 'subject:content_creators' then
    raise exception 'Kripparrian is % rather than a content creator', answer;
  end if;

  select semantic_private.concept_block(c.id, v_id) into answer
  from ontology.concepts c where c.concept_key = 'creator:johann_sebastian_bach';
  if answer is distinct from 'genre:classical' then
    raise exception 'Bach is % rather than classical', answer;
  end if;

  select semantic_private.concept_block(c.id, v_id) into answer
  from ontology.concepts c where c.concept_key = 'creator:statquest';
  if answer is distinct from 'subject:science' then
    raise exception 'StatQuest is % rather than science', answer;
  end if;

  -- The fallback: a term with no authored block still lands in its hub rather
  -- than in "Other".
  select semantic_private.concept_block(c.id, v_id) into answer
  from ontology.concepts c where c.concept_key = 'creator:ariana_grande';
  if answer is null or answer not like 'hub:%' then
    raise exception 'the hub fallback broke: Ariana Grande is %', answer;
  end if;

  raise notice '0154: blocks are the finer parent';
end;
$$;

commit;
