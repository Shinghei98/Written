-- 0143 — a channel title is a creator when the channel is professional.
--
-- **The owner's rule, 2026-08-13: "for content creators, their name is already
-- the term. It is useless to generalize them as comedy, or critic, or
-- anything. They are the terms."** That is exactly how the music side has
-- always worked — `creator:le_sserafim`, never `genre:k_pop` standing in for
-- her — and `0142` got it wrong in the other direction for seven channels.
--
-- ## The threshold, and why a statistic can carry it
--
-- **`subscriber_count` is on all 204 of one account's subscription
-- observations, and 88 are at or above 100,000.** It has been in the
-- projection since `0084` and used by nothing. A channel with a large
-- following is a public professional entity — a creator, a label, an
-- institution — rather than somebody's private upload, and that is the whole
-- argument for minting its title as vocabulary.
--
-- **It is also the argument against `EmergentTermMiner`'s five-user floor
-- applying here.** That floor exists so one person's private string cannot
-- become a public concept, which is right and has no purchase on a channel
-- with 1.46 million subscribers. The floor is untouched for everything else.
--
-- **Free, and permitted.** `channels.list` is already asked for
-- `topicDetails,statistics` in one call and quota is charged per call rather
-- than per part, so the count costs nothing — and III.E.4 lets a *statistic*
-- outlive thirty days, which is why it may sit in a stored projection at all.
-- Reading it is reading, not inferring: III.E.4.h prohibits estimating a
-- channel's category, and nothing here estimates anything. The channel's own
-- name becomes its own term.
--
-- ## What this corrects in `0142`
--
-- Seven professional channels were resolving to a subject, which is the
-- generalisation the rule above rejects: `StatQuest with Josh Starmer`
-- (1,680,000) to `subject:statistics`, `Professor Dave Explains` (4,380,000)
-- and `PanSci 泛科學` (1,210,000) to `subject:science`, `Medicosis
-- Perfectionalis` (1,810,000) to `subject:medicine`, `Learn French With Alexa`
-- (2,410,000) to `subject:language_learning`, `Dr. Trefor Bazett` (611,000)
-- and `ritvikmath` (211,000) to `subject:mathematics` and `subject:statistics`.
-- Those seven aliases are gone from the subjects family and the channels are
-- creators here.
--
-- **The threshold is what splits them, not the field.** Below 100,000 a
-- channel naming its subject is most usefully read as the subject —
-- `Bioinformagician`, `Sanbomics`, `Bioinformatics DotCa`, `NeuroscIQ`,
-- `Quimbee`, `Mu Prime Math`, `The Sheekey Science Show`, `Historical
-- Economics` all stay aliased to a subject. So the two families divide on a
-- measured property rather than on a judgement about which channels are
-- "really" about a field.
--
-- ## No relations, deliberately
--
-- Every other creator family in this ontology parents its concepts under
-- `hub:music`, because they are all musicians and it is true. These are not
-- one thing: a gaming streamer, a news organisation, a pianist, a Taiwanese
-- comedy troupe, a law-education company. Parenting them under
-- `hub:games_play` or `hub:film_video` would be inventing exactly the category
-- the owner's rule rejects, and a wrong parent is a wrong claim rather than a
-- missing one. They stand as themselves.
--
-- ## Two aliases that are not new concepts
--
-- `creator:i_dle` and `creator:jo_yuri` already exist and their *channel*
-- titles — `i-dle (아이들)` and `조유리 JO YURI` — did not resolve to them. Those
-- are aliases on the existing concepts rather than new ones, which is the
-- difference between naming a thing twice and minting it twice.
--
-- ## The list is partial and will grow on its own
--
-- Twenty-two new concepts, from the 88 subscription observations that carry a
-- `channel_id`. The other 116 do not — the `VideoPayload` defect `67b56ee`
-- fixed, whose rows are immutable — so a YouTube re-distill will surface more
-- professional channels that are catalogued but currently unreachable. That is
-- a re-run of this curation rather than a change to it.

begin;

insert into ontology.versions (id, version, parent_version_id, status, description, published_at)
select gen_random_uuid(), '0.12.0', v.id, 'draft', 'Channel titles are creators when the channel is professional.', null
from ontology.versions v where v.version = '0.11.0'
on conflict (version) do nothing;

insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
select new_v.id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
from ontology.concept_revisions r
join ontology.versions old_v on old_v.id = r.ontology_version_id and old_v.version = '0.11.0'
cross join (select id from ontology.versions where version = '0.12.0') new_v
on conflict do nothing;

insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
select new_v.id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
from ontology.concept_labels l
join ontology.versions old_v on old_v.id = l.ontology_version_id and old_v.version = '0.11.0'
cross join (select id from ontology.versions where version = '0.12.0') new_v
on conflict do nothing;

insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
select new_v.id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
from ontology.concept_edges e
join ontology.versions old_v on old_v.id = e.ontology_version_id and old_v.version = '0.11.0'
cross join (select id from ontology.versions where version = '0.12.0') new_v
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
join ontology.versions old_v on old_v.id = m.ontology_version_id and old_v.version = '0.11.0'
cross join (select id from ontology.versions where version = '0.12.0') new_v
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
  ('creator:ritvikmath', 'ritvikmath', 'creator', 'ordinary', 'inferable', 'active');

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
cross join (select id from ontology.versions where version = '0.12.0') v
on conflict (ontology_version_id, concept_id) do nothing;

insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status)
select v.id, c.id, l.label, l.normalized_label, l.locale,
       l.label_type, 'curated', 1.0, 'active'
from seed_label l
join ontology.concepts c on c.concept_key = l.concept_key
cross join (select id from ontology.versions where version = '0.12.0') v
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
cross join (select id from ontology.versions where version = '0.12.0') v
on conflict do nothing;

-- **Removing the seven aliases from the CSV did not remove them, and the
-- assertion below is what said so.** A new ontology version copies the previous
-- version's labels forward and *then* inserts the CSV's, so a row deleted from
-- a seed file is simply a row that stops being re-stated — it arrives anyway on
-- the copy. Deletion is not expressible by omission in this model, and nothing
-- about the generator hints at that.
--
-- Retired at 0.12.0 only. `0.11.0` is published and immutable and keeps them,
-- which is correct: it is the record of what the ontology said while it said it.
delete from ontology.concept_labels l
 using ontology.concepts c, ontology.versions v
 where l.concept_id = c.id
   and l.ontology_version_id = v.id
   and v.version = '0.12.0'
   and c.concept_key like 'subject:%'
   and lower(l.normalized_label) in (
     'statquest with josh starmer', 'professor dave explains',
     'pansci 泛科學', 'medicosis perfectionalis',
     'learn french with alexa', 'dr. trefor bazett', 'ritvikmath');

update ontology.versions set status = 'retired'
 where version = '0.11.0' and status = 'published';

update ontology.versions set status = 'published', published_at = now()
 where version = '0.12.0';


do $$
declare
  minted integer;
  labelled integer;
  orphan_alias integer;
  enqueued integer;
begin
  select count(*) into minted
  from ontology.concepts c
  join ontology.concept_revisions r on r.concept_id = c.id
  join ontology.versions v on v.id = r.ontology_version_id and v.version = '0.12.0'
  where c.concept_key like 'creator:%' and r.concept_kind = 'creator';
  if minted = 0 then
    raise exception 'no creator concepts exist at 0.12.0';
  end if;

  -- **Every new creator must carry a label, or it can never resolve.** `0095`
  -- minted 35 concepts that could never be reached and its own assertion passed
  -- by counting them. The point of this family is that a channel title finds a
  -- concept, so the check is that each one is findable.
  select count(*) into labelled
  from (
    select c.id
    from ontology.concepts c
    join ontology.concept_revisions r on r.concept_id = c.id
    join ontology.versions v on v.id = r.ontology_version_id and v.version = '0.12.0'
    where c.concept_key in (
      'creator:onion_man', 'creator:pewdiepie', 'creator:kripparrian',
      'creator:statquest', 'creator:asmongold', 'creator:pansci',
      'creator:cbs_news', 'creator:howfun', 'creator:ritvikmath')
      and exists (
        select 1 from ontology.concept_labels l
        where l.concept_id = c.id and l.status = 'active'
          and l.ontology_version_id = v.id)
  ) as reachable;
  if labelled <> 9 then
    raise exception
      'only % of the 9 sampled professional channels carry a label at 0.12.0', labelled;
  end if;

  -- **The seven corrected aliases must be gone from the subjects family**, or
  -- both readings survive and a channel resolves to a creator *and* a subject —
  -- double-counting one subscription as two different kinds of evidence.
  select count(*) into orphan_alias
  from ontology.concept_labels l
  join ontology.concepts c on c.id = l.concept_id
  join ontology.versions v on v.id = l.ontology_version_id and v.version = '0.12.0'
  where c.concept_key like 'subject:%' and l.status = 'active'
    and lower(l.normalized_label) in (
      'statquest with josh starmer', 'professor dave explains',
      'pansci 泛科學', 'medicosis perfectionalis',
      'learn french with alexa', 'dr. trefor bazett', 'ritvikmath');
  if orphan_alias <> 0 then
    raise exception
      '% professional channel titles still alias to a subject at 0.12.0', orphan_alias;
  end if;

  -- The ontology version *is* part of a run's identity, so publishing 0.12.0
  -- is enough to make a fresh run distinct — but nothing enqueues one on its
  -- own, which is the rule `0093` wrote and `0095` broke within the hour.
  select semantic_private.enqueue_recompute_on_analysis_change(
    'ontology 0.12.0: professional channel titles are creators'
  ) into enqueued;
  raise notice
    'ontology 0.12.0 published; % creator concepts present; % recompute job(s)',
    minted, enqueued;
end
$$;

commit;
