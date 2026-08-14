-- 0142 — subjects a channel title names, and the ontology's first non-music
-- vocabulary.
--
-- **The ontology was 1,334 concepts of which 1,111 were `creator:` — 83% —
-- and exactly five touched science, computing, medicine, education, gaming or
-- languages combined.** It was minted from one Apple Music library by `0075`
-- and CLAUDE.md already recorded that it "does not generalise". Measured on a
-- real account on 2026-08-13, it generalises worse than that: a computational
-- biology researcher's 66 YouTube subscriptions — Bioinformagician, StatQuest,
-- Swiss Institute of Bioinformatics, Medicosis Perfectionalis, Quimbee,
-- Learn French With Alexa — produced fourteen K-pop groups and four hubs.
--
-- **The signal was never weak. It had nowhere assertable to land.** Seventy of
-- his 204 subscriptions carry YouTube's own topic `Knowledge`, the third
-- commonest label on them. They resolve to `hub:ideas_learning`, which scores
-- **0.552** against a 0.35 bar and is asserted for nobody, because `0092` made
-- the scorer refuse hubs on the sound ground that a hub is a container. So the
-- diagnosis is not the eligibility bar, not the co-attestation rule and not the
-- action weights — three things this migration deliberately does not touch.
-- `hub:ideas_learning` now has children that can be asserted in its place.
--
-- ## What licenses this
--
-- Three levels, and only the middle one needs an amendment. Reading YouTube's
-- own labels onto our vocabulary is permitted outright and is already built.
-- **Assigning our own descriptive tags to a channel is what the Content
-- Categorization and Tagging amendment §3 licenses** — "additive and distinct
-- from YouTube's video categories", which `subject:bioinformatics` plainly is
-- against `Education` and `Science & Technology`. Aggregating those into a
-- claim about a *viewer* is the third level and is absent from the amendment;
-- nothing here does it, because a subject asserted about somebody is the same
-- shape of claim as a creator, which this system already makes from music.
--
-- `written_title_tag` has been a permitted `youtube_semantic_kind` since `0045`
-- and `allow_title_tags` was granted by the 2026-08-13 determination in `0135`.
-- `resolve.py` selected that column at line 847 and **used it nowhere**: the
-- permission had been granted for three days and read by nothing.
--
-- ## What is deliberately not minted
--
-- `Health` (23 of his subscriptions), `Society` (17) and `Politics` (3) stay
-- refused by `refusedTopics`, and no subject here is a route around them.
-- `subject:medicine` is the near miss and the distinction is worth stating: an
-- interest in a medical-education channel is an interest in a field, where a
-- health *status* is a protected characteristic. If that ever stops being
-- obviously true of a channel, the term goes rather than the rule.
--
-- ## The vocabulary is curated, and only half of it generalises
--
-- Aliases come in two shapes. Domain words — `Bioinformatics`, `Statistics`,
-- `Economics` — generalise to any channel naming its field, which is most of
-- the value. Whole channel titles — `StatQuest with Josh Starmer`,
-- `Bioinformagician`, `Quimbee` — do not generalise at all and are curation,
-- for the many channels whose name says nothing decomposable. That is the same
-- shape as `0134`'s creator aliases and carries the same cost: it is one
-- account's reading list until somebody else's is measured against it.
--
-- Verified before applying: sixteen of his twenty most academic channels
-- resolve, and the four that do not are `Asmongold TV`, `BABYMONSTER`,
-- `Alon Lab` and `Onion Man`.
--
-- **Only one of those four is a real miss of this vocabulary, and calling all
-- four "correct" was wrong.** `BABYMONSTER` is a creator resolved elsewhere and
-- `Alon Lab` is genuinely ambiguous. But `Asmongold TV` (4.66M subscribers) and
-- `Onion Man` (1.46M, Taiwanese comedy) are professional channels, and a
-- subject vocabulary is simply the wrong instrument for them: they are
-- *entities*, not fields. The right one is the `subscriber_count` this
-- projection already carries on all 204 of his subscriptions — 88 of them above
-- 100,000 — where a large following is evidence that the channel is a public
-- professional entity rather than somebody's private upload. That is what makes
-- minting its title as a `creator:` concept defensible against
-- `EmergentTermMiner`'s five-user floor, which exists to stop one person's
-- private string becoming public vocabulary and has no purchase on a channel
-- with a million subscribers. **Not built here**, because minting vocabulary
-- from user data is a different act from curating it and deserves its own
-- argument and its own migration.
--
-- ## Two model versions, because both behaviours changed
--
-- **Resolver 0.5.0** — `youtube_terms_for` now emits a `written_title_tag`
-- term for the channel title and for each of its tokens, gated on the run's own
-- `allow_title_tags` rather than on the approval row, so a run opened before
-- the determination is legitimately denied. Whole tokens only, never
-- substrings: `ritvikmath` stays one token and is aliased entire.
--
-- **Scorer 0.9.0** — the co-attestation rule shipped in `0138` reading
-- `bool_or(subscription) and bool_or(liked)` across every mapping for a
-- concept, which promoted `concept:fashion` at 0.190 and `medium:television` at
-- 0.314 outright on one incidental tag each from two unrelated channels. The
-- repository has carried the corrected version — intersecting the two channel
-- id sets — since it was written, and the Lambda was deployed with it before
-- this migration. A model version that lags its code makes `semantic_runs`
-- state something untrue, so the version moves here.
--
-- Deploying either alone re-scores nothing: a run's identity is `(user,
-- revision, ontology version, resolver, scorer)` and the code version is not in
-- it, which `0135` learned by enqueuing zero jobs. All three levers move
-- together and the enqueue is the last statement.

begin;

insert into ontology.versions (id, version, parent_version_id, status, description, published_at)
select gen_random_uuid(), '0.11.0', v.id, 'draft', 'Subjects a channel title names: the ontology''s first non-music vocabulary.', null
from ontology.versions v where v.version = '0.10.0'
on conflict (version) do nothing;

insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
select new_v.id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
from ontology.concept_revisions r
join ontology.versions old_v on old_v.id = r.ontology_version_id and old_v.version = '0.10.0'
cross join (select id from ontology.versions where version = '0.11.0') new_v
on conflict do nothing;

insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
select new_v.id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
from ontology.concept_labels l
join ontology.versions old_v on old_v.id = l.ontology_version_id and old_v.version = '0.10.0'
cross join (select id from ontology.versions where version = '0.11.0') new_v
on conflict do nothing;

insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
select new_v.id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
from ontology.concept_edges e
join ontology.versions old_v on old_v.id = e.ontology_version_id and old_v.version = '0.10.0'
cross join (select id from ontology.versions where version = '0.11.0') new_v
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
join ontology.versions old_v on old_v.id = m.ontology_version_id and old_v.version = '0.10.0'
cross join (select id from ontology.versions where version = '0.11.0') new_v
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
  ('subject:language_learning', 'Language learning', 'topic', 'ordinary', 'inferable', 'active');

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
  ('subject:statistics', 'StatQuest', 'statquest', 'en', 'alternate'),
  ('subject:statistics', 'StatQuest with Josh Starmer', 'statquest with josh starmer', 'en', 'alternate'),
  ('subject:statistics', 'ritvikmath', 'ritvikmath', 'en', 'alternate'),
  ('subject:mathematics', 'Mathematics', 'mathematics', 'en', 'preferred'),
  ('subject:mathematics', 'Math', 'math', 'en', 'alternate'),
  ('subject:mathematics', 'Maths', 'maths', 'en', 'alternate'),
  ('subject:mathematics', 'Mu Prime Math', 'mu prime math', 'en', 'alternate'),
  ('subject:mathematics', 'Dr. Trefor Bazett', 'dr. trefor bazett', 'en', 'alternate'),
  ('subject:machine_learning', 'Machine learning', 'machine learning', 'en', 'preferred'),
  ('subject:machine_learning', 'Machine Learning', 'machine learning', 'en', 'alternate'),
  ('subject:data_science', 'Data science', 'data science', 'en', 'preferred'),
  ('subject:data_science', 'Data Science', 'data science', 'en', 'alternate'),
  ('subject:medicine', 'Medicine', 'medicine', 'en', 'preferred'),
  ('subject:medicine', 'Medicosis Perfectionalis', 'medicosis perfectionalis', 'en', 'alternate'),
  ('subject:science', 'Science', 'science', 'en', 'preferred'),
  ('subject:science', 'Professor Dave Explains', 'professor dave explains', 'en', 'alternate'),
  ('subject:science', 'The Sheekey Science Show', 'the sheekey science show', 'en', 'alternate'),
  ('subject:science', 'PanSci 泛科學', 'pansci 泛科學', 'zh', 'alternate'),
  ('subject:science', '泛科學', '泛科學', 'zh', 'alternate'),
  ('subject:economics', 'Economics', 'economics', 'en', 'preferred'),
  ('subject:economics', 'Historical Economics', 'historical economics', 'en', 'alternate'),
  ('subject:law', 'Law', 'law', 'en', 'preferred'),
  ('subject:law', 'Quimbee', 'quimbee', 'en', 'alternate'),
  ('subject:programming', 'Programming', 'programming', 'en', 'preferred'),
  ('subject:language_learning', 'Language learning', 'language learning', 'en', 'preferred'),
  ('subject:language_learning', 'Learn French With Alexa', 'learn french with alexa', 'en', 'alternate');

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
  ('subject:language_learning', 'broader', 'hub:ideas_learning', 1.0, 'active');

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
cross join (select id from ontology.versions where version = '0.11.0') v
on conflict (ontology_version_id, concept_id) do nothing;

insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status)
select v.id, c.id, l.label, l.normalized_label, l.locale,
       l.label_type, 'curated', 1.0, 'active'
from seed_label l
join ontology.concepts c on c.concept_key = l.concept_key
cross join (select id from ontology.versions where version = '0.11.0') v
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
cross join (select id from ontology.versions where version = '0.11.0') v
on conflict do nothing;

update ontology.versions set status = 'retired'
 where version = '0.10.0' and status = 'published';

update ontology.versions set status = 'published', published_at = now()
 where version = '0.11.0';


-- Resolver 0.5.0: the channel title is read as a subject as well as a name.
insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:resolver:v0.5.0'),
  'youtube_uploader_tag_resolver', '0.5.0', 'resolver', null,
  '{"min_tag_length": 3, "whole_tag_only": true, "fuzzy": false,'
  ' "written_title_tag": "the channel title and each of its tokens, gated on'
  ' the run policy allow_title_tags; matched whole against a curated alias set,'
  ' never as a substring",'
  ' "title_tag_type_hint": "none - a subject is a topic, and the creator hint'
  ' channel_identity passes would reject every one of them on type after'
  ' resolving correctly"}'::jsonb,
  'active'
) on conflict (id) do nothing;

update ontology.model_versions
   set status = 'retired'
 where model_role = 'resolver' and version = '0.4.0' and status = 'active';

-- Scorer 0.9.0: co-attestation intersects on channel id.
insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:scorer:v0.9.0'),
  'missing_aware_late_fusion', '0.9.0', 'scorer', null,
  '{"half_weight": 6.0, "half_observations": 4.0, "eligible_strength": 0.35,'
  ' "classical_performer_min_albums": 2, "incidental_performer_weight": 0.02,'
  ' "never_asserted_kinds": ["hub"],'
  ' "work_eligible_strength": 0.25,'
  ' "spotify_top_track_weight": 0.78,'
  ' "spotify_top_artist_weight": 0.55,'
  ' "subscribed_and_liked": "a YouTube concept attested by a subscription and a'
  ' like *from the same channel* is eligible regardless of strength; the first'
  ' version tested the two independently and promoted concept:fashion on one'
  ' incidental tag from each of two unrelated artists",'
  ' "stability": "0.0 on a first run; absence of observation is not evidence"}'::jsonb,
  'active'
) on conflict (id) do nothing;

update ontology.model_versions
   set status = 'retired'
 where model_role = 'scorer' and version = '0.8.0' and status = 'active';

do $$
declare
  published integer;
  actives integer;
  subjects integer;
  labelled integer;
  parented integer;
  enqueued integer;
begin
  select count(*) into published from ontology.versions
   where status = 'published' and version = '0.11.0';
  if published <> 1 then
    raise exception '0.11.0 is not the published ontology version';
  end if;

  -- **Assert resolvability, not counts.** `0095` minted 35 concepts that could
  -- never resolve and its own assertion passed, because counting the right
  -- number of unreachable things is exactly what a structural check gets wrong.
  -- So: every subject must carry at least one active label at this version, and
  -- must sit under a hub, or it is a concept nothing can reach and nothing can
  -- explain.
  select count(*) into subjects
  from ontology.concepts c
  join ontology.concept_revisions r on r.concept_id = c.id
  join ontology.versions v on v.id = r.ontology_version_id and v.version = '0.11.0'
  where c.concept_key like 'subject:%';

  select count(distinct c.id) into labelled
  from ontology.concepts c
  join ontology.concept_labels l on l.concept_id = c.id
  join ontology.versions v on v.id = l.ontology_version_id and v.version = '0.11.0'
  where c.concept_key like 'subject:%' and l.status = 'active';

  select count(distinct subject.id) into parented
  from ontology.concept_edges e
  join ontology.concepts subject on subject.id = e.subject_concept_id
  join ontology.concepts object on object.id = e.object_concept_id
  join ontology.versions v on v.id = e.ontology_version_id and v.version = '0.11.0'
  where subject.concept_key like 'subject:%'
    and e.predicate_key = 'broader'
    and object.concept_key = 'hub:ideas_learning';

  if subjects = 0 then
    raise exception 'no subject concepts were minted at 0.11.0';
  end if;
  if labelled <> subjects then
    raise exception '% of % subjects carry no active label and can never resolve',
      subjects - labelled, subjects;
  end if;
  if parented <> subjects then
    raise exception '% of % subjects sit under no hub', subjects - parented, subjects;
  end if;

  -- **The trigger that grants a run its YouTube policy looks up the resolver by
  -- literal `model_key`.** Registering a differently-named resolver leaves that
  -- lookup empty and the trigger falls to its deny-all branch — every future
  -- run silently denied, nothing failing. Asserted rather than assumed.
  if not exists (
    select 1 from ontology.model_versions
     where model_role = 'resolver' and status = 'active'
       and model_key = 'youtube_uploader_tag_resolver'
  ) then
    raise exception
      'the active resolver is not named youtube_uploader_tag_resolver; the run policy trigger will deny every run';
  end if;

  select count(*) into actives from ontology.model_versions
   where model_role = 'resolver' and status = 'active';
  if actives <> 1 then
    raise exception 'expected exactly one active resolver, found %', actives;
  end if;
  select count(*) into actives from ontology.model_versions
   where model_role = 'scorer' and status = 'active';
  if actives <> 1 then
    raise exception 'expected exactly one active scorer, found %', actives;
  end if;

  -- **Title tags are useless without the grant, and the grant is not implied by
  -- the code.** `initialize_youtube_run_policy` copies the most recently
  -- approved determination onto each run; if none of them grants
  -- `allow_title_tags` the resolver's new branch is dead and this migration
  -- would look applied while changing nothing.
  --
  -- **The *newest* determination, not any of them.** `exists (select ... order
  -- by ... limit 1)` would answer true if any approval anywhere granted it,
  -- which is a different and much weaker claim: a later determination
  -- withdrawing the grant supersedes rather than edits, so the row that decides
  -- is the newest one and only that row.
  if not (
    select allow_title_tags
    from ontology.youtube_policy_approvals
    order by approved_at desc, approval_reference
    limit 1
  ) then
    raise exception
      'the newest YouTube determination does not grant allow_title_tags; the title reader would be dead code';
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
    'ontology 0.11.0 subjects, resolver 0.5.0 title tags, scorer 0.9.0 channel co-attestation'
  ) into enqueued;
  raise notice 'enqueued % recompute job(s)', enqueued;
end
$$;

commit;
