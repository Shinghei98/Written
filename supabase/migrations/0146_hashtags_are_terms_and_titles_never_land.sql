-- 0146 — hashtags in a video title become terms, and the title never lands.
--
-- **The owner's determination of 2026-08-13 settled the clause; this is the
-- pattern it makes available.** A hashtag is a tag the uploader typed — the
-- same kind of object as `snippet.tags`, which this projection has carried
-- since `0082` — and III.E.4 names "video titles, creator names, descriptions,
-- and comment text" without naming tags. The token is kept and the sentence it
-- came from is dropped, inside `youtubeLabels`, before anything is written.
--
-- **Read-derive-discard is the only pattern available here, and the reason is
-- mechanical rather than legal.** A title in `normalized_payload` would be
-- unremovable: `guard_observation_immutable` freezes the payload and
-- `ingestion_run_items` references observations `on delete no action` with the
-- run items append-only. `~/.claude/plans/melodic-inventing-ritchie.md` proposed
-- widening the projection to carry `title` plus a sweep that deletes
-- observations, on the premise that no trigger fires on delete — true of
-- triggers, false of foreign keys, and disproved when `0139`'s first draft
-- attempted exactly that delete. **That plan is superseded by this one**, which
-- gets what it wanted without storing what it could never remove.
--
-- ## What it is worth, measured before it was built
--
-- 983 of 1,570 liked videos carry a hashtag — **62.6%** — against `snippet.tags`
-- present on 133 of 461 projected rows. The tags themselves are not noise:
--
--     르세라핌 316   le_sserafim 204   lesserafim 130   (one group, three spellings)
--     babymonster 181   베이비몬스터 53
--     kimchaewon 146   김채원 122   chaewon 47        (a member, not the group)
--     kazuha 91   카즈하 72
--     ahyeon 73   ruka 57   chiquita 42   asa 39      (BABYMONSTER members)
--     shorts 276   kpop 120   fyp 44                  (format noise, resolves nowhere)
--
-- ## Two roles, one stored kind
--
-- `title_hashtag` takes `uploader_tag`'s treatment — the `creator` type hint,
-- no family restriction — because it *is* an uploader tag that happens to live
-- in the title. That is the opposite of `written_title_tag`, which `0142`
-- confined to the `subject:` family precisely because a channel-title *token*
-- is a word cut out of a name nobody wrote as a tag, and offering `Josh` to
-- 1,111 performer names is how a bioinformatics channel became evidence about a
-- musician.
--
-- Both store `written_title_tag`, which is the kind `0045` permits and `0135`
-- licensed, and `guard_youtube_mapping_fusion` derives the gate from the kind
-- rather than the role — so nothing else has to learn the distinction.
--
-- ## Members are their own creators
--
-- Seven of them, at their own names rather than as aliases of their groups —
-- the recorded decision of 2026-08-13: *"band members become their own creators
-- at low weight, not aliases of the group. Minting them as aliases would assert
-- a membership fact the data does not state."* `#kimchaewon` is about her.
--
-- The group aliases beside them are the other half of the same finding: the
-- ontology held `creator:le_sserafim` and had never heard of `르세라핌`, which is
-- the commonest single tag on the account. Six groups gain their Hangul names
-- and their hashtag spellings.
--
-- **`#winter` is deliberately absent.** It is an aespa member and an ordinary
-- English word, and this field is matched whole against a curated alias set —
-- so aliasing it would file every video tagged with a season under a performer.
-- The bound that makes a hashtag safe is the token, not the context.

begin;

insert into ontology.versions (id, version, parent_version_id, status, description, published_at)
select gen_random_uuid(), '0.14.0', v.id, 'draft', 'Hashtags in video titles become terms.', null
from ontology.versions v where v.version = '0.13.0'
on conflict (version) do nothing;

insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
select new_v.id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
from ontology.concept_revisions r
join ontology.versions old_v on old_v.id = r.ontology_version_id and old_v.version = '0.13.0'
cross join (select id from ontology.versions where version = '0.14.0') new_v
on conflict do nothing;

insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
select new_v.id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
from ontology.concept_labels l
join ontology.versions old_v on old_v.id = l.ontology_version_id and old_v.version = '0.13.0'
cross join (select id from ontology.versions where version = '0.14.0') new_v
on conflict do nothing;

insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
select new_v.id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
from ontology.concept_edges e
join ontology.versions old_v on old_v.id = e.ontology_version_id and old_v.version = '0.13.0'
cross join (select id from ontology.versions where version = '0.14.0') new_v
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
join ontology.versions old_v on old_v.id = m.ontology_version_id and old_v.version = '0.13.0'
cross join (select id from ontology.versions where version = '0.14.0') new_v
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
  ('hub:money_business', 'Money, work & business', 'hub', 'ordinary', 'inferable', 'active'),
  ('creator:kim_chaewon', 'Kim Chaewon', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:kazuha', 'Kazuha', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:hong_eunchae', 'Hong Eunchae', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:ahyeon', 'Ahyeon', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:ruka', 'Ruka', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:chiquita', 'Chiquita', 'creator', 'ordinary', 'inferable', 'active'),
  ('creator:asa', 'Asa', 'creator', 'ordinary', 'inferable', 'active');

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
  ('creator:jo_yuri', '조유리 JO YURI', '조유리 jo yuri', 'ko', 'alternate'),
  ('creator:kim_chaewon', 'Kim Chaewon', 'kim chaewon', 'en', 'preferred'),
  ('creator:kim_chaewon', 'kimchaewon', 'kimchaewon', 'en', 'alternate'),
  ('creator:kim_chaewon', 'chaewon', 'chaewon', 'en', 'alternate'),
  ('creator:kim_chaewon', '김채원', '김채원', 'ko', 'alternate'),
  ('creator:kazuha', 'Kazuha', 'kazuha', 'en', 'preferred'),
  ('creator:kazuha', 'kazuha', 'kazuha', 'en', 'alternate'),
  ('creator:kazuha', '카즈하', '카즈하', 'ko', 'alternate'),
  ('creator:hong_eunchae', 'Hong Eunchae', 'hong eunchae', 'en', 'preferred'),
  ('creator:hong_eunchae', 'hongeunchae', 'hongeunchae', 'en', 'alternate'),
  ('creator:hong_eunchae', 'eunchae', 'eunchae', 'en', 'alternate'),
  ('creator:ahyeon', 'Ahyeon', 'ahyeon', 'en', 'preferred'),
  ('creator:ahyeon', 'ahyeon', 'ahyeon', 'en', 'alternate'),
  ('creator:ruka', 'Ruka', 'ruka', 'en', 'preferred'),
  ('creator:ruka', 'ruka', 'ruka', 'en', 'alternate'),
  ('creator:chiquita', 'Chiquita', 'chiquita', 'en', 'preferred'),
  ('creator:chiquita', 'chiquita', 'chiquita', 'en', 'alternate'),
  ('creator:asa', 'Asa', 'asa', 'en', 'preferred'),
  ('creator:asa', 'asa', 'asa', 'en', 'alternate'),
  ('creator:le_sserafim', '르세라핌', '르세라핌', 'ko', 'alternate'),
  ('creator:le_sserafim', 'le_sserafim', 'le_sserafim', 'en', 'alternate'),
  ('creator:le_sserafim', 'lesserafim', 'lesserafim', 'en', 'alternate'),
  ('creator:babymonster', '베이비몬스터', '베이비몬스터', 'ko', 'alternate'),
  ('creator:babymonster', 'babymonster', 'babymonster', 'en', 'alternate'),
  ('creator:ive', '아이브', '아이브', 'ko', 'alternate'),
  ('creator:aespa', '에스파', '에스파', 'ko', 'alternate'),
  ('creator:twice', '트와이스', '트와이스', 'ko', 'alternate'),
  ('creator:newjeans', '뉴진스', '뉴진스', 'ko', 'alternate');

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
  ('creator:channel_miyawaki_sakura', 'broader', 'hub:music', 1.0, 'active'),
  ('creator:kim_chaewon', 'broader', 'hub:music', 1.0, 'active'),
  ('creator:kazuha', 'broader', 'hub:music', 1.0, 'active'),
  ('creator:hong_eunchae', 'broader', 'hub:music', 1.0, 'active'),
  ('creator:ahyeon', 'broader', 'hub:music', 1.0, 'active'),
  ('creator:ruka', 'broader', 'hub:music', 1.0, 'active'),
  ('creator:chiquita', 'broader', 'hub:music', 1.0, 'active'),
  ('creator:asa', 'broader', 'hub:music', 1.0, 'active');

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
cross join (select id from ontology.versions where version = '0.14.0') v
on conflict (ontology_version_id, concept_id) do nothing;

insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status)
select v.id, c.id, l.label, l.normalized_label, l.locale,
       l.label_type, 'curated', 1.0, 'active'
from seed_label l
join ontology.concepts c on c.concept_key = l.concept_key
cross join (select id from ontology.versions where version = '0.14.0') v
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
cross join (select id from ontology.versions where version = '0.14.0') v
on conflict do nothing;

update ontology.versions set status = 'retired'
 where version = '0.13.0' and status = 'published';

update ontology.versions set status = 'published', published_at = now()
 where version = '0.14.0';


-- **The projection gains one key, and the branch is closed by subtraction** —
-- an unlisted key makes the payload invalid and fails the insert, so adding the
-- field to `youtubeLabels` without adding it here would refuse every YouTube
-- row rather than ignore the new one.
--
-- `immutable` is kept. It backs a check constraint on `observations`, and
-- making it `stable` would mean dropping and re-adding that constraint, which
-- re-validates every stored row. Replacing the body does not re-validate
-- anything: rows already stored keep whatever they were accepted with, and only
-- future inserts see the wider shape.
create or replace function semantic_private.private_observation_projection_is_valid_v03(
  checked_source_code text, checked_data_type text,
  checked_observation_kind text, checked_action_type text,
  checked_occurred_at timestamp with time zone,
  checked_source_item_hmac text, checked_record_fingerprint text,
  checked_content_lineage_hmac text, checked_session_hmac text,
  checked_payload_schema_version text, checked_normalized_payload jsonb,
  checked_raw_blob_ref text, checked_field_quality double precision,
  checked_action_weight double precision, checked_privacy_class text,
  checked_allow_external_resolution boolean, checked_lifecycle_state text,
  checked_exclusion_code text,
  checked_excluded_at timestamp with time zone
) returns boolean
language plpgsql
immutable
set search_path to ''
as $$
declare
  classification_state text;
  artifact_type text;
  candidate_id text;
  controlled_label text;
  coverage_state text;
  category_id text;
  channel_id text;
  subscriber_count text;
begin
  if checked_source_code = 'youtube' then
    if checked_normalized_payload is null
       or jsonb_typeof(checked_normalized_payload) <> 'object'
       or octet_length(checked_normalized_payload::text) > 2048
       or checked_payload_schema_version <> 'youtube-v03'
       or checked_observation_kind <> 'provider_labels'
       or checked_privacy_class <> 'public_catalog'
       or checked_raw_blob_ref is not null
       or checked_session_hmac is not null
       or checked_normalized_payload ->> 'schema_version' <> 'youtube-v03'
       or checked_normalized_payload ->> 'record_kind' <> 'youtube_labels' then
      return false;
    end if;

    -- Closed by subtraction: anything not named here makes the payload
    -- non-empty and the projection invalid.
    if (checked_normalized_payload
        - 'schema_version' - 'record_kind'
        - 'topics' - 'tags' - 'category_id' - 'channel_id'
        - 'subscriber_count' - 'title_hashtags') <> '{}'::jsonb then
      return false;
    end if;

    -- **A topic has no space in it and that is the whole guard.** The distiller
    -- stores the last path component of a Wikipedia URL, so `Lifestyle_(sociology)`
    -- and `Role-playing_video_game` pass while any sentence fails.
    if checked_normalized_payload ? 'topics' then
      if jsonb_typeof(checked_normalized_payload -> 'topics') <> 'array'
         or jsonb_array_length(checked_normalized_payload -> 'topics') > 24
         or exists (
           select 1
           from jsonb_array_elements(checked_normalized_payload -> 'topics') as t
           where jsonb_typeof(t) <> 'string'
              or t #>> '{}' !~ '^[A-Za-z0-9_()''.\-]{1,80}$'
         ) then
        return false;
      end if;
    end if;

    -- Uploader tags are free text by nature, so they are bounded rather than
    -- patterned: twelve items, sixty characters, no control characters.
    if checked_normalized_payload ? 'tags' then
      if jsonb_typeof(checked_normalized_payload -> 'tags') <> 'array'
         or jsonb_array_length(checked_normalized_payload -> 'tags') > 12
         or exists (
           select 1
           from jsonb_array_elements(checked_normalized_payload -> 'tags') as t
           where jsonb_typeof(t) <> 'string'
              or char_length(t #>> '{}') not between 1 and 60
              or t #>> '{}' ~ '[[:cntrl:]]'
         ) then
        return false;
      end if;
    end if;

    -- **Hashtags out of a video title, bounded exactly as tags are.** They are
    -- the same kind of object — a token the uploader typed — and the bound is
    -- what makes them safe to keep in a store that cannot be rewritten: a
    -- hashtag ends where its word ends, so nothing here can be a sentence.
    -- Twelve of sixty, no control characters, and no whitespace at all, which
    -- is the one rule tags do not have and this needs: a tag may legitimately
    -- be `young sheldon`, while a *hashtag* containing a space would mean the
    -- extractor had taken more than the token.
    if checked_normalized_payload ? 'title_hashtags' then
      if jsonb_typeof(checked_normalized_payload -> 'title_hashtags') <> 'array'
         or jsonb_array_length(checked_normalized_payload -> 'title_hashtags') > 12
         or exists (
           select 1
           from jsonb_array_elements(checked_normalized_payload -> 'title_hashtags') as h
           where jsonb_typeof(h) <> 'string'
              or char_length(h #>> '{}') not between 2 and 60
              or h #>> '{}' ~ '[[:cntrl:][:space:]]'
              or h #>> '{}' ~ '#'
         ) then
        return false;
      end if;
    end if;

    if checked_normalized_payload ? 'category_id' then
      category_id := checked_normalized_payload ->> 'category_id';
      if category_id is null or category_id !~ '^[0-9]{1,3}$' then
        return false;
      end if;
    end if;

    if checked_normalized_payload ? 'subscriber_count' then
      subscriber_count := checked_normalized_payload ->> 'subscriber_count';
      if subscriber_count is null or subscriber_count !~ '^[0-9]{1,15}$' then
        return false;
      end if;
    end if;

    if checked_normalized_payload ? 'channel_id' then
      channel_id := checked_normalized_payload ->> 'channel_id';
      if channel_id is null or channel_id !~ '^[A-Za-z0-9_-]{3,128}$' then
        return false;
      end if;
    end if;

    -- A projection carrying none of the three label fields describes nothing,
    -- and an observation that describes nothing is not evidence. `channel_id`
    -- alone does not count: it identifies without saying anything.
    -- **A hashtag is a label, and this is the SQL twin of the same rule in
    -- `youtubeLabels`.** Both encode "an id identifies without describing" —
    -- `channel_id` and `subscriber_count` are absent from this list on purpose
    -- — and both needed the same line adding. The JavaScript one was caught by
    -- a unit test asserting a hashtag-only row is still an observation; this
    -- one was caught by this migration's own probe, which refused a payload
    -- carrying nothing but hashtags. Two guards, one rule, and it had to be
    -- said twice because neither side can see the other.
    return checked_normalized_payload
             ?| array['topics', 'tags', 'category_id', 'title_hashtags'];
  end if;

  if not semantic_private.is_private_lane_source(checked_source_code) then
    return true;
  end if;
  if checked_source_item_hmac is null
     or checked_source_item_hmac !~ '^[0-9a-f]{64}$'
     or checked_record_fingerprint is null
     or checked_record_fingerprint !~ '^[0-9a-f]{64}$'
     or (
       checked_content_lineage_hmac is not null
       and checked_content_lineage_hmac !~ '^[0-9a-f]{64}$'
     )
     or checked_session_hmac is not null
     or checked_raw_blob_ref is not null
     or checked_field_quality is null
     or checked_field_quality < 0.0
     or checked_field_quality > 1.0
     or checked_allow_external_resolution is distinct from false
     or checked_normalized_payload is null
     or jsonb_typeof(checked_normalized_payload) <> 'object'
     or octet_length(checked_normalized_payload::text) > 1024 then
    return false;
  end if;
  if not (
    (
      checked_lifecycle_state = 'active'
      and checked_exclusion_code is null
      and checked_excluded_at is null
    ) or (
      checked_lifecycle_state in ('excluded', 'deleted')
      and checked_exclusion_code in (
        'policy_excluded', 'user_deleted', 'retention_expired',
        'superseded', 'legacy_sanitized'
      )
      and checked_excluded_at is not null
    )
  ) then
    return false;
  end if;

  if semantic_private.is_private_calendar_source(checked_source_code) then
    classification_state := checked_normalized_payload ->> 'classification_state';
    artifact_type := checked_normalized_payload ->> 'artifact_type';
    if checked_data_type <> 'calendar_event'
       or checked_observation_kind <> 'sanitized_classification'
       or checked_action_type not in ('scheduled', 'booked')
       or checked_payload_schema_version <> 'calendar-v03'
       or checked_privacy_class <> 'private_calendar_sanitized'
       or checked_action_weight <> 0.0
       or checked_normalized_payload ->> 'schema_version' <> 'calendar-v03'
       or checked_normalized_payload ->> 'record_kind'
         <> 'calendar_classification'
       or classification_state not in ('candidate', 'excluded', 'review') then
      return false;
    end if;
    if classification_state = 'candidate' then
      return coalesce(
        checked_occurred_at is not null
        and checked_content_lineage_hmac is not null
        and artifact_type in (
          'travel_itinerary', 'commercial_reservation', 'public_ticket'
        )
        and checked_normalized_payload = jsonb_build_object(
          'schema_version', 'calendar-v03',
          'record_kind', 'calendar_classification',
          'classification_state', 'candidate',
          'artifact_type', artifact_type
        ), false
      );
    end if;
    return coalesce(
      checked_normalized_payload = jsonb_build_object(
        'schema_version', 'calendar-v03',
        'record_kind', 'calendar_classification',
        'classification_state', classification_state
      ), false
    );
  end if;

  candidate_id := checked_normalized_payload ->> 'candidate_id';
  controlled_label := checked_normalized_payload ->> 'controlled_label';
  coverage_state := checked_normalized_payload ->> 'coverage_state';
  return coalesce(checked_data_type = 'fitness_habit'
    and checked_observation_kind = 'routine_projection'
    and checked_action_type = 'routine'
    and checked_occurred_at is not null
    and checked_content_lineage_hmac is null
    and checked_payload_schema_version
      = 'written-healthkit-fitness-v1.0.0'
    and checked_privacy_class = 'private_fitness_sanitized'
    and checked_action_weight = 0.85
    and jsonb_typeof(checked_normalized_payload -> 'candidate_id') = 'string'
    and candidate_id ~
      '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and jsonb_typeof(checked_normalized_payload -> 'controlled_label') = 'string'
    and char_length(controlled_label) between 1 and 120
    and controlled_label !~ '[[:cntrl:]]'
    and coverage_state in ('workout_typed', 'mixed')
    and checked_normalized_payload = jsonb_build_object(
      'schema_version', 'written-healthkit-fitness-v1.0.0',
      'record_kind', 'fitness_habit',
      'classification_state', 'candidate',
      'candidate_id', candidate_id,
      'controlled_label', controlled_label,
      'coverage_state', coverage_state,
      'purpose_scope', 'fitness_connection',
      'policy_version', 'written-healthkit-fitness-v1.0.0'
    ), false);
end;
$$;

-- Resolver 0.6.0: hashtags are read.
insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:resolver:v0.6.0'),
  'youtube_uploader_tag_resolver', '0.6.0', 'resolver', null,
  '{"min_tag_length": 3, "whole_tag_only": true, "fuzzy": false,'
  ' "written_title_tag": "channel title and its tokens, confined to the subject'
  ' family; a token cut out of a name is not a tag anybody wrote",'
  ' "title_hashtag": "hashtags extracted from a video title at ingestion and'
  ' stored as tokens; the title itself is never stored. Takes the creator type'
  ' hint like uploader_tag, because it is an uploader tag that lives in the'
  ' title. Stored kind is written_title_tag for both."}'::jsonb,
  'active'
) on conflict (id) do nothing;

update ontology.model_versions
   set status = 'retired'
 where model_role = 'resolver' and version = '0.5.0' and status = 'active';

do $$
declare
  version_id uuid;
  members integer;
  group_aliases integer;
  actives integer;
  enqueued integer;
begin
  select id into version_id from ontology.versions where version = '0.14.0';

  -- **Prove the predicate both ways, over the exact shape being shipped.**
  -- `0117` asserted a rule over an empty table and answered false for
  -- everything while passing its own check; the guard against that is calling
  -- the function and requiring both answers.
  if not semantic_private.private_observation_projection_is_valid_v03(
       'youtube', 'liked_video', 'provider_labels', 'liked_video', now(),
       'a', 'b', null, null, 'youtube-v03',
       '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
         "title_hashtags":["youngsheldon","르세라핌"]}'::jsonb,
       null, 1.0, 0.5, 'public_catalog', false, 'active', null, null) then
    raise exception 'a projection carrying title_hashtags is refused';
  end if;

  -- A hashtag containing a space would mean the extractor took more than the
  -- token — the failure this field exists to make impossible.
  if semantic_private.private_observation_projection_is_valid_v03(
       'youtube', 'liked_video', 'provider_labels', 'liked_video', now(),
       'a', 'b', null, null, 'youtube-v03',
       '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
         "title_hashtags":["young sheldon"]}'::jsonb,
       null, 1.0, 0.5, 'public_catalog', false, 'active', null, null) then
    raise exception 'a hashtag containing whitespace was accepted';
  end if;

  -- And the title itself is still refused, which is the property this whole
  -- migration is built around.
  if semantic_private.private_observation_projection_is_valid_v03(
       'youtube', 'liked_video', 'provider_labels', 'liked_video', now(),
       'a', 'b', null, null, 'youtube-v03',
       '{"schema_version":"youtube-v03","record_kind":"youtube_labels",
         "title":"Sheldon ran a red light"}'::jsonb,
       null, 1.0, 0.5, 'public_catalog', false, 'active', null, null) then
    raise exception 'a projection carrying a title was accepted';
  end if;

  select count(*) into members
  from ontology.concepts c
  join ontology.concept_revisions r on r.concept_id = c.id
   and r.ontology_version_id = version_id
  where c.concept_key in ('creator:kim_chaewon','creator:kazuha',
    'creator:hong_eunchae','creator:ahyeon','creator:ruka',
    'creator:chiquita','creator:asa');
  if members <> 7 then
    raise exception 'only % of 7 member concepts exist at 0.14.0', members;
  end if;

  -- **The group aliases join `ontology.concepts` by key**, so an alias for a
  -- concept the CSVs never defined lands only if the database already holds it
  -- — and writes nothing, silently, if it does not. These six are DB-only
  -- concepts minted by the music tooling, so the join is the whole risk.
  select count(*) into group_aliases
  from ontology.concept_labels l
  join ontology.concepts c on c.id = l.concept_id
  where l.ontology_version_id = version_id and l.status = 'active'
    and lower(l.normalized_label) in
      ('르세라핌','베이비몬스터','아이브','에스파','트와이스','뉴진스');
  if group_aliases <> 6 then
    raise exception
      'only % of 6 Hangul group aliases landed; the concept_key join found nothing',
      group_aliases;
  end if;

  select count(*) into actives from ontology.model_versions
   where model_role = 'resolver' and status = 'active';
  if actives <> 1 then
    raise exception 'expected exactly one active resolver, found %', actives;
  end if;
  if not exists (
    select 1 from ontology.model_versions
     where model_role = 'resolver' and status = 'active'
       and model_key = 'youtube_uploader_tag_resolver'
  ) then
    raise exception 'the active resolver is misnamed; the run policy trigger will deny every run';
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
    'ontology 0.14.0 members and group aliases, resolver 0.6.0 title hashtags'
  ) into enqueued;
  raise notice 'enqueued % recompute job(s)', enqueued;
end
$$;

commit;
