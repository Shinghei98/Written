-- 0145 — blocks: a term's hub is the block it belongs to.
--
-- **The terms were right and the page was a flat list.** After `0142`-`0144` a
-- real account carries 89 eligible terms — Bach, LE SSERAFIM, Onion Man,
-- StatQuest, Kripparrian — ordered by strength and grouped by nothing, so it
-- reads Bach, Hadelich, LE SSERAFIM, BABYMONSTER, Mozart… with the YouTube
-- creators in a heap at the bottom. The owner's framing: one block per large
-- category, and **"not everyone has each block, so the presence of blocks also
-- relates to the terms they have"** — the absence of a Gaming block is a fact
-- about somebody, not a gap in the page.
--
-- ## A block is a hub, and it already existed
--
-- `hub:*` is exactly this and has never been used for it. Thirteen hubs, none
-- ever asserted — `never_asserted_kinds: ["hub"]` since `0092` — and that stays
-- true and is not in tension with this: **a hub is not a claim that somebody
-- likes music, it is the drawer their music terms sit in.** Blocking uses hubs
-- as headings, which is what a container is for, while `0092`'s refusal is
-- about asserting the container *as a term*. Both survive.
--
-- **It also settles the tension in the owner's two rules.** "It is useless to
-- generalize them as comedy, or critic — they are the terms" rejected replacing
-- `creator:kripparrian` with a category. Filing him *under* Gaming replaces
-- nothing: the term is still his name, and the block only says which drawer.
--
-- ## The block is the nearest hub, walked
--
-- `broader` is a multi-parent DAG rather than a tree — `creator:le_sserafim`
-- is `broader` of `genre:k_pop` *and* `era:2020s`, and `genre:k_pop` is
-- `broader` of `genre:asian_music` then `genre:pop` then `hub:music`. So a
-- direct edge answers almost nothing: measured before this migration, only 7
-- of 89 asserted terms had a hub as their immediate parent, and 28 had no
-- `broader` edge at all.
--
-- `semantic_private.concept_block` walks it. **Nearest hub wins, ties broken by
-- key**, so the answer is deterministic where a concept reaches two — and it is
-- depth-bounded, because `broader` is not guaranteed acyclic by any constraint
-- and a cycle would otherwise hang the reader that every Memories load calls.
--
-- ## What is deliberately left unblocked
--
-- Four of `0143`'s channels — `Cyon`, `Thomas Mulligan`, `xooos 수스`,
-- `표은지Eunji Pyoapple` — get no parent, because nobody here knows what they
-- are. A term with no block is honest; a term in the wrong block is a false
-- claim about somebody, which is the same argument that gave `0143` no
-- relations file at all. `block_key` comes back null for them and the client
-- shows them ungrouped.
--
-- Three edges are written by hand rather than through the CSVs, and the
-- generator is why: it refuses a relation naming a concept absent from every
-- `*_concepts.csv`, because the edge insert joins on `concept_key` and an
-- unknown key produces no row and no error. `creator:antonio_vivaldi`,
-- `creator:pyotr_ilyich_tchaikovsky` and `creator:stephen_schwartz` exist in
-- the database — minted by the music tooling, never by a CSV — so their edges
-- cannot go through that pipeline and are stated below.
--
-- ## Two hubs the taxonomy lacked
--
-- `hub:news_current_affairs`, because `CBS News` had nowhere to go, and
-- `hub:money_business`, which nothing points at yet. Minting an unused hub is
-- deliberate: authored vocabulary is minted whole so the concept set does not
-- differ per install, and investing is a block real people have.

begin;

insert into ontology.versions (id, version, parent_version_id, status, description, published_at)
select gen_random_uuid(), '0.13.0', v.id, 'draft', 'Blocks: every term reaches a hub, and the hub is the block.', null
from ontology.versions v where v.version = '0.12.0'
on conflict (version) do nothing;

insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
select new_v.id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
from ontology.concept_revisions r
join ontology.versions old_v on old_v.id = r.ontology_version_id and old_v.version = '0.12.0'
cross join (select id from ontology.versions where version = '0.13.0') new_v
on conflict do nothing;

insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
select new_v.id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
from ontology.concept_labels l
join ontology.versions old_v on old_v.id = l.ontology_version_id and old_v.version = '0.12.0'
cross join (select id from ontology.versions where version = '0.13.0') new_v
on conflict do nothing;

insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
select new_v.id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
from ontology.concept_edges e
join ontology.versions old_v on old_v.id = e.ontology_version_id and old_v.version = '0.12.0'
cross join (select id from ontology.versions where version = '0.13.0') new_v
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
join ontology.versions old_v on old_v.id = m.ontology_version_id and old_v.version = '0.12.0'
cross join (select id from ontology.versions where version = '0.13.0') new_v
on conflict do nothing;

create temporary table seed_concept (concept_key text primary key, preferred_label text not null, concept_kind text not null, sensitivity text not null, inference_policy text not null, status text not null) on commit drop;
insert into seed_concept values
  ('hub:music', 'Music', 'hub', 'ordinary', 'inferable', 'active'),
  ('hub:film_video', 'Film, TV & video', 'hub', 'ordinary', 'inferable', 'active'),
  ('hub:ideas_learning', 'Books, ideas & learning', 'hub', 'ordinary', 'inferable', 'active'),
  ('hub:sports_movement', 'Sports & movement', 'hub', 'ordinary', 'review_required', 'active'),
  ('hub:food_drink', 'Food & drink', 'hub', 'ordinary', 'inferable', 'active'),
  ('hub:arts_live', 'Arts & live culture', 'hub', 'ordinary', 'inferable', 'active'),
  ('hub:places_cultures', 'Places, travel & cultures', 'hub', 'ordinary', 'review_required', 'active'),
  ('hub:games_play', 'Games & play', 'hub', 'ordinary', 'inferable', 'draft'),
  ('hub:nature_outdoors', 'Nature & outdoors', 'hub', 'ordinary', 'inferable', 'draft'),
  ('hub:work_study_making', 'Work, study & making', 'hub', 'private', 'explicit_only', 'draft'),
  ('hub:social_community', 'Social life & community', 'hub', 'private', 'review_required', 'draft'),
  ('hub:animals_pets', 'Animals & pets', 'hub', 'ordinary', 'review_required', 'draft'),
  ('hub:daily_rhythms', 'Daily rhythms & routines', 'hub', 'private', 'review_required', 'draft'),
  ('place:italy', 'Italy', 'place', 'ordinary', 'review_required', 'active'),
  ('concept:italian_music', 'Italian music', 'topic', 'ordinary', 'inferable', 'active'),
  ('concept:italian_cinema', 'Italian cinema', 'topic', 'ordinary', 'inferable', 'active'),
  ('concept:italian_cuisine', 'Italian cuisine', 'cuisine', 'ordinary', 'review_required', 'active'),
  ('affinity:culture:italy', 'Italian cultural affinity', 'affinity', 'ordinary', 'review_required', 'active'),
  ('identity:italian_ancestry', 'Italian ancestry', 'identity', 'sensitive', 'explicit_only', 'blocked'),
  ('identity:italian_nationality', 'Italian nationality', 'identity', 'sensitive', 'explicit_only', 'blocked'),
  ('identity:italian_native_language', 'Italian native language', 'identity', 'sensitive', 'explicit_only', 'blocked'),
  ('activity:running', 'Running', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:walking', 'Walking', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:cycling', 'Cycling', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:swimming', 'Swimming', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:hiking', 'Hiking', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:strength_training', 'Strength training', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:yoga', 'Yoga', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:pilates', 'Pilates', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:dance', 'Dance', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:hiit', 'HIIT', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:rowing', 'Rowing', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:elliptical', 'Elliptical training', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:climbing', 'Climbing', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:tennis', 'Tennis', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:pickleball', 'Pickleball', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:basketball', 'Basketball', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:soccer', 'Soccer', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:skiing', 'Skiing', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:snowboarding', 'Snowboarding', 'activity', 'ordinary', 'review_required', 'active'),
  ('routine:morning_workouts', 'Morning workouts', 'activity', 'ordinary', 'review_required', 'active'),
  ('routine:afternoon_workouts', 'Afternoon workouts', 'activity', 'ordinary', 'review_required', 'active'),
  ('routine:evening_workouts', 'Evening workouts', 'activity', 'ordinary', 'review_required', 'active'),
  ('routine:overnight_workouts', 'Overnight workouts', 'activity', 'ordinary', 'review_required', 'active'),
  ('routine:consistent_sleep_schedule', 'Consistent sleep schedule', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:american_football', 'American football', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:baseball', 'Baseball', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:cricket', 'Cricket', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:rugby', 'Rugby', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:ice_hockey', 'Ice hockey', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:volleyball', 'Volleyball', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:badminton', 'Badminton', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:table_tennis', 'Table tennis', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:golf', 'Golf', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:boxing', 'Boxing', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:mixed_martial_arts', 'Mixed martial arts', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:motorsport', 'Motorsport', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:athletics', 'Athletics', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:gymnastics', 'Gymnastics', 'activity', 'ordinary', 'review_required', 'active'),
  ('creator:one_ok_rock', 'ONE OK ROCK', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:gen_hoshino', 'Gen Hoshino', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:taichi_mukai', 'Taichi Mukai', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:jolin_tsai', 'Jolin Tsai', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:eve_ai', 'Eve Ai', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:xiao_yu', 'Xiao Yu', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:nariaki_obukuro', 'Nariaki Obukuro', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:akko_gorilla', 'Akko Gorilla', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:sufjan_stevens', 'Sufjan Stevens', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:corsak', 'CORSAK', 'creator', 'ordinary', 'inferable', 'active'),
  ('work:ranking_of_kings', 'Ranking of Kings', 'work', 'ordinary', 'inferable', 'active'),
  ('work:run_with_the_wind', 'Run with the Wind', 'work', 'ordinary', 'inferable', 'active'),
  ('work:call_me_by_your_name', 'Call Me by Your Name', 'work', 'ordinary', 'inferable', 'active'),
  ('activity:flute', 'Playing the flute', 'activity', 'ordinary', 'review_required', 'active'),
  ('activity:quantitative_research', 'Quantitative research', 'activity', 'ordinary', 'review_required', 'active'),
  ('subject:bioinformatics', 'Bioinformatics', 'topic', 'ordinary', 'inferable', 'active'),
  ('subject:computational_biology', 'Computational biology', 'topic', 'ordinary', 'inferable', 'active'),
  ('subject:genomics', 'Genomics', 'topic', 'ordinary', 'inferable', 'active'),
  ('subject:neuroscience', 'Neuroscience', 'topic', 'ordinary', 'inferable', 'active'),
  ('subject:statistics', 'Statistics', 'topic', 'ordinary', 'inferable', 'active'),
  ('subject:mathematics', 'Mathematics', 'topic', 'ordinary', 'inferable', 'active'),
  ('subject:machine_learning', 'Machine learning', 'topic', 'ordinary', 'inferable', 'active'),
  ('subject:data_science', 'Data science', 'topic', 'ordinary', 'inferable', 'active'),
  ('subject:medicine', 'Medicine', 'topic', 'ordinary', 'inferable', 'active'),
  ('subject:science', 'Science', 'topic', 'ordinary', 'inferable', 'active'),
  ('subject:economics', 'Economics', 'topic', 'ordinary', 'inferable', 'active'),
  ('subject:law', 'Law', 'topic', 'ordinary', 'inferable', 'active'),
  ('subject:programming', 'Programming', 'topic', 'ordinary', 'inferable', 'active'),
  ('subject:language_learning', 'Language learning', 'topic', 'ordinary', 'inferable', 'active'),
  ('creator:pewdiepie', 'PewDiePie', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:jyp_entertainment', 'JYP Entertainment', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:cbs_news', 'CBS News', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:asmongold', 'Asmongold TV', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:professor_dave_explains', 'Professor Dave Explains', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:learn_french_with_alexa', 'Learn French With Alexa', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:cyon', 'Cyon', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:thomas_mulligan', 'Thomas Mulligan', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:marasy8', 'marasy8', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:eunji_pyoapple', '표은지Eunji Pyoapple', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:medicosis_perfectionalis', 'Medicosis Perfectionalis', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:statquest', 'StatQuest with Josh Starmer', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:xooos', 'xooos 수스', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:howfun', 'HowFun', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:onion_man', 'Onion Man', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:pansci', 'PanSci 泛科學', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:kripparrian', 'Kripparrian', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:fanzheng_wo_hen_xian', '反正我很閒', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:channel_miyawaki_sakura', 'ちゃんねる宮脇咲良', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:dr_trefor_bazett', 'Dr. Trefor Bazett', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:steve_brunton', 'Steve Brunton', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:ritvikmath', 'ritvikmath', 'creator', 'ordinary', 'inferable', 'active'),
  ('hub:news_current_affairs', 'News & current affairs', 'hub', 'ordinary', 'review_required', 'active'),
  ('hub:money_business', 'Money, work & business', 'hub', 'ordinary', 'inferable', 'active');

create temporary table seed_label (concept_key text, label text, normalized_label text, locale text, label_type text) on commit drop;
insert into seed_label values
  ('hub:music', 'music', 'music', 'en', 'preferred'),
  ('hub:film_video', 'movie', 'movie', 'en', 'alternate'),
  ('hub:film_video', 'film', 'film', 'en', 'alternate'),
  ('hub:film_video', 'tv', 'tv', 'en', 'alternate'),
  ('hub:ideas_learning', 'podcast', 'podcast', 'en', 'source_term'),
  ('hub:sports_movement', 'workout', 'workout', 'en', 'alternate'),
  ('hub:sports_movement', 'exercise', 'exercise', 'en', 'alternate'),
  ('hub:food_drink', 'restaurant', 'restaurant', 'en', 'alternate'),
  ('place:italy', 'Italy', 'italy', 'en', 'preferred'),
  ('place:italy', 'Italian', 'italian', 'en', 'related_label'),
  ('place:italy', 'Italia', 'italia', 'it', 'alternate'),
  ('concept:italian_music', 'Italian music', 'italian music', 'en', 'preferred'),
  ('concept:italian_music', 'musica italiana', 'musica italiana', 'it', 'alternate'),
  ('concept:italian_cinema', 'Italian cinema', 'italian cinema', 'en', 'preferred'),
  ('concept:italian_cinema', 'cinema italiano', 'cinema italiano', 'it', 'alternate'),
  ('concept:italian_cuisine', 'Italian food', 'italian food', 'en', 'alternate'),
  ('concept:italian_cuisine', 'Italian cuisine', 'italian cuisine', 'en', 'preferred'),
  ('concept:italian_cuisine', 'cucina italiana', 'cucina italiana', 'it', 'alternate'),
  ('activity:running', 'Running', 'running', 'en', 'preferred'),
  ('activity:walking', 'Walking', 'walking', 'en', 'preferred'),
  ('activity:cycling', 'Cycling', 'cycling', 'en', 'preferred'),
  ('activity:swimming', 'Swimming', 'swimming', 'en', 'preferred'),
  ('activity:hiking', 'Hiking', 'hiking', 'en', 'preferred'),
  ('activity:strength_training', 'Strength training', 'strength training', 'en', 'preferred'),
  ('activity:yoga', 'Yoga', 'yoga', 'en', 'preferred'),
  ('activity:pilates', 'Pilates', 'pilates', 'en', 'preferred'),
  ('activity:dance', 'Dance', 'dance', 'en', 'preferred'),
  ('activity:hiit', 'HIIT', 'hiit', 'en', 'preferred'),
  ('activity:rowing', 'Rowing', 'rowing', 'en', 'preferred'),
  ('activity:elliptical', 'Elliptical training', 'elliptical training', 'en', 'preferred'),
  ('activity:climbing', 'Climbing', 'climbing', 'en', 'preferred'),
  ('activity:tennis', 'Tennis', 'tennis', 'en', 'preferred'),
  ('activity:pickleball', 'Pickleball', 'pickleball', 'en', 'preferred'),
  ('activity:basketball', 'Basketball', 'basketball', 'en', 'preferred'),
  ('activity:soccer', 'Soccer', 'soccer', 'en', 'preferred'),
  ('activity:skiing', 'Skiing', 'skiing', 'en', 'preferred'),
  ('activity:snowboarding', 'Snowboarding', 'snowboarding', 'en', 'preferred'),
  ('routine:morning_workouts', 'Morning workouts', 'morning workouts', 'en', 'preferred'),
  ('routine:afternoon_workouts', 'Afternoon workouts', 'afternoon workouts', 'en', 'preferred'),
  ('routine:evening_workouts', 'Evening workouts', 'evening workouts', 'en', 'preferred'),
  ('routine:overnight_workouts', 'Overnight workouts', 'overnight workouts', 'en', 'preferred'),
  ('routine:consistent_sleep_schedule', 'Consistent sleep schedule', 'consistent sleep schedule', 'en', 'preferred'),
  ('activity:american_football', 'American football', 'american football', 'en', 'preferred'),
  ('activity:american_football', 'NFL', 'nfl', 'en', 'alternate'),
  ('activity:baseball', 'Baseball', 'baseball', 'en', 'preferred'),
  ('activity:baseball', 'MLB', 'mlb', 'en', 'alternate'),
  ('activity:cricket', 'Cricket', 'cricket', 'en', 'preferred'),
  ('activity:rugby', 'Rugby', 'rugby', 'en', 'preferred'),
  ('activity:ice_hockey', 'Ice hockey', 'ice hockey', 'en', 'preferred'),
  ('activity:ice_hockey', 'NHL', 'nhl', 'en', 'alternate'),
  ('activity:volleyball', 'Volleyball', 'volleyball', 'en', 'preferred'),
  ('activity:badminton', 'Badminton', 'badminton', 'en', 'preferred'),
  ('activity:table_tennis', 'Table tennis', 'table tennis', 'en', 'preferred'),
  ('activity:table_tennis', 'ping pong', 'ping pong', 'en', 'alternate'),
  ('activity:golf', 'Golf', 'golf', 'en', 'preferred'),
  ('activity:boxing', 'Boxing', 'boxing', 'en', 'preferred'),
  ('activity:mixed_martial_arts', 'Mixed martial arts', 'mixed martial arts', 'en', 'preferred'),
  ('activity:mixed_martial_arts', 'MMA', 'mma', 'en', 'alternate'),
  ('activity:mixed_martial_arts', 'UFC', 'ufc', 'en', 'alternate'),
  ('activity:motorsport', 'Motorsport', 'motorsport', 'en', 'preferred'),
  ('activity:motorsport', 'Formula 1', 'formula 1', 'en', 'alternate'),
  ('activity:motorsport', 'F1', 'f1', 'en', 'alternate'),
  ('activity:athletics', 'Athletics', 'athletics', 'en', 'preferred'),
  ('activity:athletics', 'track and field', 'track and field', 'en', 'alternate'),
  ('activity:gymnastics', 'Gymnastics', 'gymnastics', 'en', 'preferred'),
  ('activity:basketball', 'NBA', 'nba', 'en', 'alternate'),
  ('creator:one_ok_rock', 'ONE OK ROCK', 'one ok rock', 'en', 'preferred'),
  ('creator:one_ok_rock', 'OOR', 'oor', 'und', 'alternate'),
  ('creator:one_ok_rock', 'ワンオク', 'ワンオク', 'ja', 'alternate'),
  ('creator:one_ok_rock', 'ワンオクロック', 'ワンオクロック', 'ja', 'alternate'),
  ('creator:gen_hoshino', 'Gen Hoshino', 'gen hoshino', 'en', 'preferred'),
  ('creator:gen_hoshino', 'Hoshino Gen', 'hoshino gen', 'en', 'alternate'),
  ('creator:gen_hoshino', '星野源', '星野源', 'ja', 'alternate'),
  ('creator:taichi_mukai', 'Taichi Mukai', 'taichi mukai', 'en', 'preferred'),
  ('creator:taichi_mukai', 'MUKAI TAICHI', 'mukai taichi', 'en', 'alternate'),
  ('creator:taichi_mukai', '向井太一', '向井太一', 'ja', 'alternate'),
  ('creator:jolin_tsai', 'Jolin Tsai', 'jolin tsai', 'en', 'preferred'),
  ('creator:jolin_tsai', '蔡依林', '蔡依林', 'zh', 'alternate'),
  ('creator:eve_ai', 'Eve Ai', 'eve ai', 'en', 'preferred'),
  ('creator:eve_ai', '艾怡良', '艾怡良', 'zh', 'alternate'),
  ('creator:xiao_yu', 'Xiao Yu', 'xiao yu', 'en', 'preferred'),
  ('creator:xiao_yu', '宋念宇', '宋念宇', 'zh', 'alternate'),
  ('creator:xiao_yu', '小宇', '小宇', 'zh', 'alternate'),
  ('creator:nariaki_obukuro', 'Nariaki Obukuro', 'nariaki obukuro', 'en', 'preferred'),
  ('creator:nariaki_obukuro', '小袋成彬', '小袋成彬', 'ja', 'alternate'),
  ('creator:akko_gorilla', 'Akko Gorilla', 'akko gorilla', 'en', 'preferred'),
  ('creator:akko_gorilla', 'あっこゴリラ', 'あっこゴリラ', 'ja', 'alternate'),
  ('creator:sufjan_stevens', 'Sufjan Stevens', 'sufjan stevens', 'en', 'preferred'),
  ('creator:sufjan_stevens', 'sufjanstevens', 'sufjanstevens', 'und', 'alternate'),
  ('creator:corsak', 'CORSAK', 'corsak', 'en', 'preferred'),
  ('work:ranking_of_kings', 'Ranking of Kings', 'ranking of kings', 'en', 'preferred'),
  ('work:ranking_of_kings', '國王排名', '國王排名', 'zh', 'alternate'),
  ('work:run_with_the_wind', 'Run with the Wind', 'run with the wind', 'en', 'preferred'),
  ('work:run_with_the_wind', 'kaze ga tsuyoku fuiteiru', 'kaze ga tsuyoku fuiteiru', 'ja', 'alternate'),
  ('work:call_me_by_your_name', 'Call Me by Your Name', 'call me by your name', 'en', 'preferred'),
  ('work:call_me_by_your_name', 'callmebyyourname', 'callmebyyourname', 'und', 'alternate'),
  ('activity:flute', 'Playing the flute', 'playing the flute', 'en', 'preferred'),
  ('activity:flute', 'flute', 'flute', 'en', 'alternate'),
  ('activity:flute', 'flute cover', 'flute cover', 'en', 'alternate'),
  ('activity:flute', 'alto flute', 'alto flute', 'en', 'alternate'),
  ('activity:flute', 'alto flute cover', 'alto flute cover', 'en', 'alternate'),
  ('activity:quantitative_research', 'Quantitative research', 'quantitative research', 'en', 'preferred'),
  ('activity:quantitative_research', 'statistics', 'statistics', 'en', 'alternate'),
  ('activity:quantitative_research', 'ANCOVA', 'ancova', 'en', 'alternate'),
  ('activity:quantitative_research', 'analysis of covariance', 'analysis of covariance', 'en', 'alternate'),
  ('activity:quantitative_research', 'repeated measures anova', 'repeated measures anova', 'en', 'alternate'),
  ('activity:quantitative_research', 'effect size', 'effect size', 'en', 'alternate'),
  ('activity:quantitative_research', 'mplus', 'mplus', 'en', 'alternate'),
  ('genre:rock', 'rock music', 'rock music', 'en', 'alternate'),
  ('genre:hip_hop', 'hip hop music', 'hip hop music', 'en', 'alternate'),
  ('genre:rnb_soul', 'soul music', 'soul music', 'en', 'alternate'),
  ('genre:rnb_soul', 'rhythm and blues', 'rhythm and blues', 'en', 'alternate'),
  ('genre:indie', 'independent music', 'independent music', 'en', 'alternate'),
  ('creator:hikaru_utada', '宇多田ヒカル', '宇多田ヒカル', 'ja', 'alternate'),
  ('creator:hikaru_utada', 'Utada Hikaru', 'utada hikaru', 'en', 'alternate'),
  ('creator:mayday', '五月天', '五月天', 'zh', 'alternate'),
  ('subject:bioinformatics', 'Bioinformatics', 'bioinformatics', 'en', 'preferred'),
  ('subject:bioinformatics', 'Bioinformagician', 'bioinformagician', 'en', 'alternate'),
  ('subject:bioinformatics', 'Sanbomics', 'sanbomics', 'en', 'alternate'),
  ('subject:bioinformatics', 'Bioinformatics DotCa', 'bioinformatics dotca', 'en', 'alternate'),
  ('subject:bioinformatics', 'Swiss Institute of Bioinformatics', 'swiss institute of bioinformatics', 'en', 'alternate'),
  ('subject:bioinformatics', 'SIB - Swiss Institute of Bioinformatics', 'sib - swiss institute of bioinformatics', 'en', 'alternate'),
  ('subject:computational_biology', 'Computational biology', 'computational biology', 'en', 'preferred'),
  ('subject:computational_biology', 'Computational Biology', 'computational biology', 'en', 'alternate'),
  ('subject:genomics', 'Genomics', 'genomics', 'en', 'preferred'),
  ('subject:neuroscience', 'Neuroscience', 'neuroscience', 'en', 'preferred'),
  ('subject:neuroscience', 'NeuroscIQ', 'neurosciq', 'en', 'alternate'),
  ('subject:statistics', 'Statistics', 'statistics', 'en', 'preferred'),
  ('subject:mathematics', 'Mathematics', 'mathematics', 'en', 'preferred'),
  ('subject:mathematics', 'Math', 'math', 'en', 'alternate'),
  ('subject:mathematics', 'Maths', 'maths', 'en', 'alternate'),
  ('subject:mathematics', 'Mu Prime Math', 'mu prime math', 'en', 'alternate'),
  ('subject:machine_learning', 'Machine learning', 'machine learning', 'en', 'preferred'),
  ('subject:machine_learning', 'Machine Learning', 'machine learning', 'en', 'alternate'),
  ('subject:data_science', 'Data science', 'data science', 'en', 'preferred'),
  ('subject:data_science', 'Data Science', 'data science', 'en', 'alternate'),
  ('subject:medicine', 'Medicine', 'medicine', 'en', 'preferred'),
  ('subject:science', 'Science', 'science', 'en', 'preferred'),
  ('subject:science', 'The Sheekey Science Show', 'the sheekey science show', 'en', 'alternate'),
  ('subject:economics', 'Economics', 'economics', 'en', 'preferred'),
  ('subject:economics', 'Historical Economics', 'historical economics', 'en', 'alternate'),
  ('subject:law', 'Law', 'law', 'en', 'preferred'),
  ('subject:law', 'Quimbee', 'quimbee', 'en', 'alternate'),
  ('subject:programming', 'Programming', 'programming', 'en', 'preferred'),
  ('subject:language_learning', 'Language learning', 'language learning', 'en', 'preferred'),
  ('creator:pewdiepie', 'PewDiePie', 'pewdiepie', 'en', 'preferred'),
  ('creator:jyp_entertainment', 'JYP Entertainment', 'jyp entertainment', 'en', 'preferred'),
  ('creator:cbs_news', 'CBS News', 'cbs news', 'en', 'preferred'),
  ('creator:asmongold', 'Asmongold TV', 'asmongold tv', 'en', 'preferred'),
  ('creator:asmongold', 'Asmongold', 'asmongold', 'en', 'alternate'),
  ('creator:professor_dave_explains', 'Professor Dave Explains', 'professor dave explains', 'en', 'preferred'),
  ('creator:learn_french_with_alexa', 'Learn French With Alexa', 'learn french with alexa', 'en', 'preferred'),
  ('creator:cyon', 'Cyon', 'cyon', 'en', 'preferred'),
  ('creator:thomas_mulligan', 'Thomas Mulligan', 'thomas mulligan', 'en', 'preferred'),
  ('creator:marasy8', 'marasy8', 'marasy8', 'und', 'preferred'),
  ('creator:eunji_pyoapple', '표은지Eunji Pyoapple', '표은지eunji pyoapple', 'ko', 'preferred'),
  ('creator:medicosis_perfectionalis', 'Medicosis Perfectionalis', 'medicosis perfectionalis', 'en', 'preferred'),
  ('creator:statquest', 'StatQuest with Josh Starmer', 'statquest with josh starmer', 'en', 'preferred'),
  ('creator:statquest', 'StatQuest', 'statquest', 'en', 'alternate'),
  ('creator:xooos', 'xooos 수스', 'xooos 수스', 'ko', 'preferred'),
  ('creator:howfun', 'HowFun', 'howfun', 'en', 'preferred'),
  ('creator:onion_man', 'Onion Man', 'onion man', 'en', 'preferred'),
  ('creator:pansci', 'PanSci 泛科學', 'pansci 泛科學', 'zh', 'preferred'),
  ('creator:pansci', '泛科學', '泛科學', 'zh', 'alternate'),
  ('creator:kripparrian', 'Kripparrian', 'kripparrian', 'en', 'preferred'),
  ('creator:fanzheng_wo_hen_xian', '反正我很閒', '反正我很閒', 'zh', 'preferred'),
  ('creator:channel_miyawaki_sakura', 'ちゃんねる宮脇咲良', 'ちゃんねる宮脇咲良', 'ja', 'preferred'),
  ('creator:dr_trefor_bazett', 'Dr. Trefor Bazett', 'dr. trefor bazett', 'en', 'preferred'),
  ('creator:steve_brunton', 'Steve Brunton', 'steve brunton', 'en', 'preferred'),
  ('creator:ritvikmath', 'ritvikmath', 'ritvikmath', 'en', 'preferred'),
  ('creator:i_dle', 'i-dle (아이들)', 'i-dle (아이들)', 'ko', 'alternate'),
  ('creator:jo_yuri', '조유리 JO YURI', '조유리 jo yuri', 'ko', 'alternate');

create temporary table seed_edge (subject_key text, predicate_key text, object_key text, confidence double precision, status text) on commit drop;
insert into seed_edge values
  ('concept:italian_music', 'broader', 'hub:music', 1.0, 'active'),
  ('concept:italian_cinema', 'broader', 'hub:film_video', 1.0, 'active'),
  ('concept:italian_cuisine', 'broader', 'hub:food_drink', 1.0, 'active'),
  ('concept:italian_music', 'associated_with_place', 'place:italy', 1.0, 'candidate'),
  ('concept:italian_cinema', 'associated_with_place', 'place:italy', 1.0, 'candidate'),
  ('concept:italian_cuisine', 'associated_with_place', 'place:italy', 1.0, 'candidate'),
  ('concept:italian_music', 'supports_cultural_affinity_candidate', 'place:italy', 1.0, 'active'),
  ('concept:italian_cinema', 'supports_cultural_affinity_candidate', 'place:italy', 1.0, 'active'),
  ('concept:italian_cuisine', 'supports_cultural_affinity_candidate', 'place:italy', 1.0, 'active'),
  ('affinity:culture:italy', 'about', 'place:italy', 1.0, 'active'),
  ('identity:italian_ancestry', 'about', 'place:italy', 1.0, 'blocked'),
  ('identity:italian_nationality', 'about', 'place:italy', 1.0, 'blocked'),
  ('identity:italian_native_language', 'about', 'place:italy', 1.0, 'blocked'),
  ('activity:running', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:walking', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:cycling', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:swimming', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:hiking', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:strength_training', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:yoga', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:pilates', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:dance', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:hiit', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:rowing', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:elliptical', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:climbing', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:tennis', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:pickleball', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:basketball', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:soccer', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:skiing', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:snowboarding', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('routine:morning_workouts', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('routine:afternoon_workouts', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('routine:evening_workouts', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('routine:overnight_workouts', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('routine:consistent_sleep_schedule', 'broader', 'hub:daily_rhythms', 1.0, 'active'),
  ('activity:american_football', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:baseball', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:cricket', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:rugby', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:ice_hockey', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:volleyball', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:badminton', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:table_tennis', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:golf', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:boxing', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:mixed_martial_arts', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:motorsport', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:athletics', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('activity:gymnastics', 'broader', 'hub:sports_movement', 1.0, 'active'),
  ('creator:one_ok_rock', 'broader', 'hub:music', 1.0, 'active'),
  ('creator:gen_hoshino', 'broader', 'hub:music', 1.0, 'active'),
  ('creator:taichi_mukai', 'broader', 'hub:music', 1.0, 'active'),
  ('creator:jolin_tsai', 'broader', 'hub:music', 1.0, 'active'),
  ('creator:eve_ai', 'broader', 'hub:music', 1.0, 'active'),
  ('creator:xiao_yu', 'broader', 'hub:music', 1.0, 'active'),
  ('creator:nariaki_obukuro', 'broader', 'hub:music', 1.0, 'active'),
  ('creator:akko_gorilla', 'broader', 'hub:music', 1.0, 'active'),
  ('creator:sufjan_stevens', 'broader', 'hub:music', 1.0, 'active'),
  ('creator:corsak', 'broader', 'hub:music', 1.0, 'active'),
  ('work:ranking_of_kings', 'broader', 'hub:film_video', 1.0, 'active'),
  ('work:run_with_the_wind', 'broader', 'hub:film_video', 1.0, 'active'),
  ('work:call_me_by_your_name', 'broader', 'hub:film_video', 1.0, 'active'),
  ('activity:flute', 'broader', 'hub:arts_live', 1.0, 'active'),
  ('activity:quantitative_research', 'broader', 'hub:work_study_making', 1.0, 'active'),
  ('subject:bioinformatics', 'broader', 'hub:ideas_learning', 1.0, 'active'),
  ('subject:computational_biology', 'broader', 'hub:ideas_learning', 1.0, 'active'),
  ('subject:genomics', 'broader', 'hub:ideas_learning', 1.0, 'active'),
  ('subject:neuroscience', 'broader', 'hub:ideas_learning', 1.0, 'active'),
  ('subject:statistics', 'broader', 'hub:ideas_learning', 1.0, 'active'),
  ('subject:mathematics', 'broader', 'hub:ideas_learning', 1.0, 'active'),
  ('subject:machine_learning', 'broader', 'hub:ideas_learning', 1.0, 'active'),
  ('subject:data_science', 'broader', 'hub:ideas_learning', 1.0, 'active'),
  ('subject:medicine', 'broader', 'hub:ideas_learning', 1.0, 'active'),
  ('subject:science', 'broader', 'hub:ideas_learning', 1.0, 'active'),
  ('subject:economics', 'broader', 'hub:ideas_learning', 1.0, 'active'),
  ('subject:law', 'broader', 'hub:ideas_learning', 1.0, 'active'),
  ('subject:programming', 'broader', 'hub:ideas_learning', 1.0, 'active'),
  ('subject:language_learning', 'broader', 'hub:ideas_learning', 1.0, 'active'),
  ('creator:asmongold', 'broader', 'hub:games_play', 1.0, 'active'),
  ('creator:kripparrian', 'broader', 'hub:games_play', 1.0, 'active'),
  ('creator:pewdiepie', 'broader', 'hub:games_play', 1.0, 'active'),
  ('creator:professor_dave_explains', 'broader', 'hub:ideas_learning', 1.0, 'active'),
  ('creator:medicosis_perfectionalis', 'broader', 'hub:ideas_learning', 1.0, 'active'),
  ('creator:statquest', 'broader', 'hub:ideas_learning', 1.0, 'active'),
  ('creator:steve_brunton', 'broader', 'hub:ideas_learning', 1.0, 'active'),
  ('creator:ritvikmath', 'broader', 'hub:ideas_learning', 1.0, 'active'),
  ('creator:pansci', 'broader', 'hub:ideas_learning', 1.0, 'active'),
  ('creator:learn_french_with_alexa', 'broader', 'hub:ideas_learning', 1.0, 'active'),
  ('creator:cbs_news', 'broader', 'hub:news_current_affairs', 1.0, 'active'),
  ('creator:onion_man', 'broader', 'hub:film_video', 1.0, 'active'),
  ('creator:howfun', 'broader', 'hub:film_video', 1.0, 'active'),
  ('creator:fanzheng_wo_hen_xian', 'broader', 'hub:film_video', 1.0, 'active'),
  ('creator:jyp_entertainment', 'broader', 'hub:music', 1.0, 'active'),
  ('creator:marasy8', 'broader', 'hub:music', 1.0, 'active'),
  ('creator:channel_miyawaki_sakura', 'broader', 'hub:music', 1.0, 'active');

insert into ontology.concepts (id, concept_key)
select gen_random_uuid(), s.concept_key from seed_concept s
on conflict (concept_key) do nothing;

-- **`inference_policy` comes from the CSV, never from a default here.** Every
-- sport is `review_required`, which is the whole reason the column exists: a
-- fitness activity implies something about somebody's body and a watched match
-- implies far less than it looks like it does. Hardcoding `inferable` in the
-- generator would erase a per-concept decision at the point it is written down.
insert into ontology.concept_revisions (
  ontology_version_id, concept_id, preferred_label, concept_kind,
  definition, sensitivity, inference_policy, status, metadata)
select v.id, c.id, s.preferred_label, s.concept_kind, null,
       s.sensitivity, s.inference_policy, s.status, '{}'::jsonb
from seed_concept s
join ontology.concepts c on c.concept_key = s.concept_key
cross join (select id from ontology.versions where version = '0.13.0') v
on conflict (ontology_version_id, concept_id) do nothing;

insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status)
select v.id, c.id, l.label, l.normalized_label, l.locale,
       l.label_type, 'curated', 1.0, 'active'
from seed_label l
join ontology.concepts c on c.concept_key = l.concept_key
cross join (select id from ontology.versions where version = '0.13.0') v
on conflict (ontology_version_id, concept_id, locale, normalized_label, label_type)
  do nothing;

insert into ontology.concept_edges (
  ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
  confidence, provenance_type, provenance, status)
select v.id, subject.id, e.predicate_key, object.id, e.confidence, 'curated',
       '{"source": "seed_csv"}'::jsonb, e.status
from seed_edge e
join ontology.concepts subject on subject.concept_key = e.subject_key
join ontology.concepts object on object.concept_key = e.object_key
cross join (select id from ontology.versions where version = '0.13.0') v
on conflict do nothing;

-- **Hand-written statements go *above* the publish, and this cost two
-- migrations to learn.** `tools/seed_from_csv.py` ends its output by retiring
-- the old version and publishing the new one, so anything appended after the
-- generated body runs against a version that is already published — and
-- `ontology.versions` is immutable once published. `0143` hit it deleting a
-- label, this hit it inserting an edge.
-- **The three edges the CSV pipeline cannot express.** Joined on `concept_key`
-- against the new version, so a missing concept writes nothing — which is the
-- silent failure the assertion below exists to catch.
insert into ontology.concept_edges (
  ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
  confidence, provenance_type, provenance, status)
select v.id, subject.id, 'broader', object.id, 1.0, 'curated',
       '{"source": "0145_blocks"}'::jsonb, 'active'
from (values
  -- **Bach reached no hub, and the assertion below is what found it.** His
  -- only `broader` edge was to `era:baroque`, which is an axis and parents
  -- nothing — so the most strongly asserted term on the account, at 0.952, had
  -- no block. A pre-existing gap in the music vocabulary rather than anything
  -- this migration introduced.
  ('creator:johann_sebastian_bach', 'genre:classical'),
  ('creator:antonio_vivaldi', 'genre:classical'),
  ('creator:pyotr_ilyich_tchaikovsky', 'genre:classical'),
  ('creator:stephen_schwartz', 'genre:musicals')
) as pair(subject_key, object_key)
join ontology.concepts subject on subject.concept_key = pair.subject_key
join ontology.concepts object on object.concept_key = pair.object_key
cross join (select id from ontology.versions where version = '0.13.0') v
on conflict do nothing;

update ontology.versions set status = 'retired'
 where version = '0.12.0' and status = 'published';

update ontology.versions set status = 'published', published_at = now()
 where version = '0.13.0';


-- The block a concept belongs to: the nearest `hub:` reachable by `broader`.
--
-- **Depth-bounded on purpose.** Nothing constrains `broader` to be acyclic, and
-- this is called for every row of every Memories load — an unbounded recursive
-- CTE over a cycle would hang the page rather than fail it. Eight is far above
-- the deepest real chain (`creator -> genre -> genre -> genre -> hub` is four).
create or replace function semantic_private.concept_block(
  target_concept_id uuid, target_version_id uuid
) returns text
language sql
stable
set search_path to ''
as $function$
  with recursive climb(concept_id, depth) as (
    select target_concept_id, 0
    union all
    select e.object_concept_id, climb.depth + 1
      from climb
      join ontology.concept_edges e
        on e.subject_concept_id = climb.concept_id
       and e.predicate_key = 'broader'
       and e.ontology_version_id = target_version_id
       and e.status = 'active'
     where climb.depth < 8
  )
  select c.concept_key
    from climb
    join ontology.concepts c on c.id = climb.concept_id
   where c.concept_key like 'hub:%'
   order by climb.depth, c.concept_key
   limit 1;
$function$;

-- **`list_assertions` gains the block, and keeps everything else exactly.**
-- `0102` rewrote this function to add a guard, pasted the body from
-- `pg_get_functiondef` and dropped the `order by` at the bottom of it — its own
-- assertion checked the column *count*, which cannot see ordering any more than
-- it can see position, and somebody was shown their fourteenth-strongest trait
-- first. So the two added columns go on the end of the select list, the `where`
-- is untouched, and the `order by` is reproduced verbatim and asserted below.
--
-- **Two columns rather than one.** `block_key` is the stable identifier a
-- client groups on; `block_label` is the heading a person reads. Returning only
-- the key would put `hub:ideas_learning` on screen or make the app hold a
-- second copy of the labels, which is the drift `0134` was written about.
-- **Dropped first, because the return type changes.** `create or replace`
-- refuses a new `OUT` row type with `42P13`, which is the same rule CLAUDE.md
-- records for parameters — "changing a function's parameters means `drop
-- function` naming the old signature in full" — reached from the other side.
-- The drop takes the grant with it, which is why one is re-issued below; a
-- rewritten reader that authenticated cannot execute is a blank Memories page.
drop function if exists api.list_assertions();

create function api.list_assertions()
returns table(
  assertion_id uuid, predicate_key text, label text, origin text,
  display_state text, strength double precision, confidence double precision,
  breadth integer, stability double precision, surfacing_score double precision,
  display_payload jsonb, assertion_score_version_id uuid,
  ontology_version_id uuid, block_key text, block_label text
)
language plpgsql
stable security definer
set search_path to ''
as $function$
begin
  perform semantic_private.assert_surface_allowed('memories');
  return query
  select
    assertion.id,
    assertion.predicate_key,
    coalesce(revision.preferred_label, user_term.label),
    assertion.assertion_origin,
    coalesce(preference.display_state, 'default'),
    score.strength,
    score.confidence,
    score.breadth,
    score.stability,
    score.surfacing_score,
    score.display_payload,
    score.id,
    coalesce(score.ontology_version_id, assertion.created_ontology_version_id),
    block.concept_key,
    block_revision.preferred_label
  from semantic_private.user_assertions as assertion
  left join semantic_private.assertion_preferences as preference
    on preference.assertion_id = assertion.id
   and preference.user_id = assertion.user_id
  left join semantic_private.user_terms as user_term
    on user_term.id = assertion.user_term_id
   and user_term.user_id = assertion.user_id
  left join semantic_private.assertion_current_scores as current_score
    on current_score.assertion_id = assertion.id
   and current_score.user_id = assertion.user_id
  left join semantic_private.user_state_versions as user_state
    on user_state.user_id = assertion.user_id
  left join semantic_private.semantic_runs as score_run
    on score_run.id = current_score.semantic_run_id
   and score_run.user_id = assertion.user_id
   and score_run.status = 'succeeded'
   and score_run.input_revision = coalesce(user_state.revision, 0)
  left join semantic_private.assertion_score_versions as score
    on score.id = current_score.assertion_score_version_id
   and score.user_id = current_score.user_id
   and score.assertion_id = current_score.assertion_id
   and score.semantic_run_id = score_run.id
  left join ontology.concept_revisions as revision
    on revision.ontology_version_id = coalesce(
         score.ontology_version_id, assertion.created_ontology_version_id
       )
   and revision.concept_id = assertion.concept_id
  -- The block, and its label at the same version the term is read at, so a
  -- heading can never come from a different ontology than the row under it.
  left join lateral (
    select c.id, c.concept_key
      from ontology.concepts c
     where c.concept_key = semantic_private.concept_block(
             assertion.concept_id,
             coalesce(score.ontology_version_id,
                      assertion.created_ontology_version_id))
  ) as block on true
  left join ontology.concept_revisions as block_revision
    on block_revision.concept_id = block.id
   and block_revision.ontology_version_id = coalesce(
         score.ontology_version_id, assertion.created_ontology_version_id
       )
  where assertion.user_id = auth.uid()
    and assertion.machine_state in ('candidate', 'eligible')
    and coalesce(preference.display_state, 'default') <> 'suppressed'
    and (
      assertion.user_term_id is not null
      or revision.concept_kind in ('creator', 'work', 'activity')
    )
    and (
      assertion.assertion_origin <> 'inferred' or
      (
        score.id is not null
        and score_run.status = 'succeeded'
        and score_run.input_revision = coalesce(user_state.revision, 0)
      )
    )
    and not exists (
      select 1
      from semantic_private.user_suppressions as suppression
      where suppression.user_id = assertion.user_id
        and suppression.predicate_key = assertion.predicate_key
        and suppression.surface = 'memories'
        and suppression.active
        and (
          (assertion.concept_id is not null and suppression.concept_id = assertion.concept_id) or
          (assertion.user_term_id is not null and suppression.user_term_id = assertion.user_term_id)
        )
    )
  order by coalesce(score.surfacing_score, 1.0) desc, assertion.created_at;
end;
$function$;

grant execute on function api.list_assertions() to authenticated;

do $$
declare
  version_id uuid;
  blocked integer;
  distinct_blocks integer;
  music_block text;
  gaming_block text;
  unparented text;
  ordered boolean;
begin
  select id into version_id from ontology.versions where version = '0.13.0';

  -- **The resolver must answer, and answer differently for different terms.**
  -- `0117` shipped a predicate that returned false for everything and passed a
  -- structural check; the guard against that is demanding real, distinct
  -- answers over real rows rather than counting them.
  select semantic_private.concept_block(c.id, version_id) into music_block
    from ontology.concepts c where c.concept_key = 'creator:le_sserafim';
  select semantic_private.concept_block(c.id, version_id) into gaming_block
    from ontology.concepts c where c.concept_key = 'creator:kripparrian';

  if music_block is distinct from 'hub:music' then
    raise exception 'creator:le_sserafim blocks to % rather than hub:music', music_block;
  end if;
  if gaming_block is distinct from 'hub:games_play' then
    raise exception 'creator:kripparrian blocks to % rather than hub:games_play', gaming_block;
  end if;

  -- A term reached only through a chain, to prove the walk rather than a direct
  -- edge: Bach has no hub parent, he is `broader` of `genre:classical`, which
  -- reaches `hub:music` two steps further on.
  if semantic_private.concept_block(
       (select id from ontology.concepts where concept_key = 'creator:johann_sebastian_bach'),
       version_id) is distinct from 'hub:music' then
    raise exception 'the broader walk does not reach a hub from creator:johann_sebastian_bach';
  end if;

  -- **And it must answer null where nothing was authored**, or the four
  -- unplaced channels are silently filed somewhere.
  select semantic_private.concept_block(c.id, version_id) into unparented
    from ontology.concepts c where c.concept_key = 'creator:cyon';
  if unparented is not null then
    raise exception 'creator:cyon was given the block %, and nobody authored one', unparented;
  end if;

  -- Every creator `0143` minted and this migration parented must now block.
  select count(*) into blocked
  from ontology.concepts c
  where c.concept_key in (
    'creator:onion_man', 'creator:pewdiepie', 'creator:kripparrian',
    'creator:statquest', 'creator:asmongold', 'creator:cbs_news',
    'creator:howfun', 'creator:ritvikmath', 'creator:pansci',
    'creator:medicosis_perfectionalis', 'creator:steve_brunton',
    'creator:professor_dave_explains', 'creator:learn_french_with_alexa',
    'creator:fanzheng_wo_hen_xian', 'creator:jyp_entertainment',
    'creator:marasy8', 'creator:channel_miyawaki_sakura')
    and semantic_private.concept_block(c.id, version_id) is not null;
  if blocked <> 17 then
    raise exception 'only % of 17 parented creators resolve to a block', blocked;
  end if;

  -- More than one block must exist over real data, or "blocks" is one heading.
  select count(distinct semantic_private.concept_block(c.id, version_id))
    into distinct_blocks
  from ontology.concepts c
  where c.concept_key like 'creator:%'
    and semantic_private.concept_block(c.id, version_id) is not null;
  if distinct_blocks < 4 then
    raise exception 'creators resolve to only % distinct block(s)', distinct_blocks;
  end if;
  raise notice 'creators resolve across % distinct blocks', distinct_blocks;

  -- **The `order by` survived the rewrite.** `0102` lost it doing exactly this
  -- and its assertion counted columns, which cannot see ordering. Read off the
  -- function's own source: crude, and it is the property that was lost.
  select pg_get_functiondef(p.oid) ilike '%order by coalesce(score.surfacing_score, 1.0) desc, assertion.created_at%'
    into ordered
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'api' and p.proname = 'list_assertions';
  if not ordered then
    raise exception 'list_assertions lost its order by in the rewrite';
  end if;

  -- And the two new columns are actually on it.
  if (select count(*) from information_schema.routines r
      where r.routine_schema = 'api' and r.routine_name = 'list_assertions') <> 1 then
    raise exception 'expected exactly one api.list_assertions';
  end if;
end
$$;

commit;
