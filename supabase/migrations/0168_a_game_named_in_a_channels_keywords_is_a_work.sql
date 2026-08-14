-- 0168 — a game named in a channel's own keywords is a work.
--
-- ## What was wrong
--
-- A real account subscribes to Kripparrian, whose channel keywords are
-- `Hearthstone|HS|Meta|Lucky Hearthstone|Rank 1|…`, and Memories shows no game
-- at all. Measured 2026-08-14, four separate things stood between the two and
-- this migration is the third and fourth of them:
--
--   1. **The keywords never reached the vault.** `YouTubeDistiller` writes them
--      as `keywords=` and `SourcePayload+Legacy.swift` read `tags` — 2,134
--      `uploader_tag` mappings from liked videos and zero from subscriptions.
--      Fixed in the app; it takes a fresh distillation, since the vault payload
--      is frozen and append-only.
--   2. **`uploader_tag` passes the type hint `creator`**, so a tag could only
--      ever be evidence about a person or a band. `resolve.py` now emits a
--      second term, `uploader_tag_work` — two readings of one act, kept as two
--      roles so they can be weighed apart later, both on the stored kind
--      `uploader_tag` and both gated on `allow_uploader_tags`, because `0078`
--      licenses the act and not a family of concept.
--
--      **It emits a key from a catalogue rather than the raw tag, and the
--      measurement is the reason.** Passing the tag with the hint `work`
--      reaches every active `work` alias — 50 of them, three ordinary English
--      words: `bleach`, `wicked`, `overlord`, each minted from a music library
--      and each defined *"Read from a music library; never inferred from a
--      title."* One account's own subscriptions already collide, `Anime Man
--      Talks` tagging `Bleach`, and any channel tagging `wicked` would have
--      been handed a Broadway cast recording. Those aliases cannot be
--      withdrawn — `work:wicked` stands at 0.683 on 30 music rows *because* of
--      that alias — so the lane narrows instead of the vocabulary, which is
--      `work_titles.mjs`'s rule applied one layer down: an alias must not be a
--      word, and where the ontology holds one anyway, free text may not reach
--      it. `GAME_TAG_CATALOGUE` in `aws/worker/resolve.py` is that lane's
--      vocabulary, as `tools/youtube_topics.py` is `provider_topic`'s.
--   3. **There was no Hearthstone concept.** The ontology's entire games
--      vocabulary was four `genre:*` concepts, and a genre is withheld from
--      Memories by `list_assertions`' kind allowlist — so 43 accepted mappings
--      to `genre:strategy_game` and 86 to `genre:action_game` asserted nothing
--      and could not have. This mints three works under `hub:games_play`.
--   4. **`work` rather than `topic`,** which is the decision underneath. A game
--      is a named bounded thing, the same class as `work:wicked`; `work` is on
--      the allowlist and is judged at 0.25 rather than 0.35, on `0149`'s
--      argument that the same strength means more evidence for a work.
--
--   5. **The vocabulary and the lane were not enough, and the arithmetic says
--      so before anybody looks.** Calibrated on this account: one subscription
--      carries one lineage and reaches strength 0.035 — `creator:kripparrian`
--      is 0.0352 — while `work:footloose_the_musical` clears the 0.25 work bar
--      at 0.2663 on seven evidence rows. A game named by one channel lands at
--      roughly a seventh of its bar. So `score.py` gains **scorer 0.14.0**: a
--      subscribed channel asserts the works its own keywords name, exactly as
--      it already asserts its own creator.
--
-- ## The rule, and the objection it has to answer
--
-- The creator rule states its own limit, and the limit is exact: *"subscribing
-- to Bioinformagician declares that you follow Bioinformagician, and it does
-- not declare bioinformatics — a subject is something you would have to
-- aggregate across channels."* That refusal stands untouched. A work is the
-- other thing. `Hearthstone` in Kripparrian's keyword list is not a theme
-- abstracted from what he posts; it is the name of the object the channel is
-- about, written by its owner, and reading it aggregates nothing. `subject:*`
-- still has to accumulate and still does.
--
-- **A weight could not express this either**, which is the same reason the
-- creator rule is a rule: `w/(w+6)` rewards accumulation, and you cannot
-- subscribe twice. There is nothing further to accumulate, so a bar calibrated
-- on accumulation is unreachable at any weight.
--
-- **Bounded twice, and the bounds are what make it safe.** `GAME_TAG_CATALOGUE`
-- is authored, so this cannot admit an arbitrary keyword; and the promotion
-- tests `concept_kind = 'work'`, which the type system makes exact — a
-- creator-hinted term is refused on type against a work, and `title_work`
-- stores a different kind, so an `uploader_tag` mapping on a subscription that
-- reached a work can only have come from the work reading.
--
-- **The cost, stated rather than discovered.** Somebody subscribed to a games
-- channel gets that game as a term whether they play it or watch it. That is
-- the trade the creator rule already accepted for sixty catalogued
-- subscriptions — every one of them true, ranked by strength so the strongest
-- reads first, and struck off in one tap if wrong. The assertion is
-- `affinity_to`, which is what it already means for a creator nobody claims
-- you have met.
--
-- ## Generated, and then hand-extended
--
-- The body is `tools/seed_from_csv.py --from 0.20.0 --to 0.21.0`; change
-- `semantic/ontology/games_*.csv` and regenerate rather than editing it.
-- **Everything after the version publish is hand-added and regenerating drops
-- it** — the hub activation, the three model versions and the enqueue. That is
-- the standing arrangement for this generator, which by design emits no
-- recompute enqueue.
--
-- **All the levers move together and the enqueue is the last statement**, which
-- is `0142`'s lesson: a run's identity is `(user, revision, ontology version,
-- resolver, scorer)`, the code version is not in it, and `0135` learned that by
-- enqueuing zero jobs. Splitting the scorer into its own migration would have
-- enqueued one round of work against 0.13.0 and thrown it away an instant
-- later.
--
-- 122 concepts, 205 labels, 107 edges — the
-- whole hand-authored core, not only what is new. Every insert is
-- `on conflict do nothing` and 0.21.0 copies 0.20.0 forward first, so re-stating
-- an existing concept is a no-op.
--
-- A published ontology version is immutable, so this mints 0.21.0 from 0.20.0 and
-- publishes last — publishing is also retiring, since only one version may be
-- published at a time.

begin;

insert into ontology.versions (id, version, parent_version_id, status, description, published_at)
select gen_random_uuid(), '0.21.0', v.id, 'draft', 'A game named in a channel''s own keywords is a work.', null
from ontology.versions v where v.version = '0.20.0'
on conflict (version) do nothing;

insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
select new_v.id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
from ontology.concept_revisions r
join ontology.versions old_v on old_v.id = r.ontology_version_id and old_v.version = '0.20.0'
cross join (select id from ontology.versions where version = '0.21.0') new_v
on conflict do nothing;

insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
select new_v.id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
from ontology.concept_labels l
join ontology.versions old_v on old_v.id = l.ontology_version_id and old_v.version = '0.20.0'
cross join (select id from ontology.versions where version = '0.21.0') new_v
on conflict do nothing;

insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
select new_v.id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
from ontology.concept_edges e
join ontology.versions old_v on old_v.id = e.ontology_version_id and old_v.version = '0.20.0'
cross join (select id from ontology.versions where version = '0.21.0') new_v
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
join ontology.versions old_v on old_v.id = m.ontology_version_id and old_v.version = '0.20.0'
cross join (select id from ontology.versions where version = '0.21.0') new_v
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
  ('creator:asa', 'Asa', 'creator', 'ordinary', 'inferable', 'active'),
  ('work:hearthstone', 'Hearthstone', 'work', 'ordinary', 'inferable', 'active'),
  ('work:world_of_warcraft', 'World of Warcraft', 'work', 'ordinary', 'inferable', 'active'),
  ('work:final_fantasy_xiv', 'Final Fantasy XIV', 'work', 'ordinary', 'inferable', 'active');

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
  ('creator:newjeans', '뉴진스', '뉴진스', 'ko', 'alternate'),
  ('work:hearthstone', 'Hearthstone', 'hearthstone', 'en', 'preferred'),
  ('work:hearthstone', 'work:hearthstone', 'work:hearthstone', 'und', 'alternate'),
  ('work:world_of_warcraft', 'World of Warcraft', 'world of warcraft', 'en', 'preferred'),
  ('work:world_of_warcraft', 'work:world_of_warcraft', 'work:world_of_warcraft', 'und', 'alternate'),
  ('work:final_fantasy_xiv', 'Final Fantasy XIV', 'final fantasy xiv', 'en', 'preferred'),
  ('work:final_fantasy_xiv', 'work:final_fantasy_xiv', 'work:final_fantasy_xiv', 'und', 'alternate');

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
  ('creator:asa', 'broader', 'hub:music', 1.0, 'active'),
  ('work:hearthstone', 'broader', 'hub:games_play', 1.0, 'active'),
  ('work:world_of_warcraft', 'broader', 'hub:games_play', 1.0, 'active'),
  ('work:final_fantasy_xiv', 'broader', 'hub:games_play', 1.0, 'active');

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
cross join (select id from ontology.versions where version = '0.21.0') v
on conflict (ontology_version_id, concept_id) do nothing;

insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status)
select v.id, c.id, l.label, l.normalized_label, l.locale,
       l.label_type, 'curated', 1.0, 'active'
from seed_label l
join ontology.concepts c on c.concept_key = l.concept_key
cross join (select id from ontology.versions where version = '0.21.0') v
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
cross join (select id from ontology.versions where version = '0.21.0') v
on conflict do nothing;

-- Hand-added, and it must stay above the publish. **The hub stops being
-- hypothetical.** `seed_concepts.csv` files `hub:games_play` as `draft` with
-- the note *"Not directly observed in the current V1 sources"*, which stopped
-- being true when `0145` parented Kripparrian, Asmongold and PewDiePie under it
-- and stops being true again here. The generator adds and never edits — `on
-- conflict do nothing` makes a changed CSV status a silent no-op — so the
-- change has to be an update against the new version, and
-- `concept_revisions_guard_published` raises *published or retired ontology
-- versions are immutable* the moment 0.21.0 is published. Regenerating from the
-- CSVs drops this too.
update ontology.concept_revisions r
   set status = 'active'
  from ontology.concepts c, ontology.versions v
 where c.id = r.concept_id and c.concept_key = 'hub:games_play'
   and v.id = r.ontology_version_id and v.version = '0.21.0'
   and r.status = 'draft';

update ontology.versions set status = 'retired'
 where version = '0.20.0' and status = 'published';

update ontology.versions set status = 'published', published_at = now()
 where version = '0.21.0';


-- ---------------------------------------------------------------------------
-- Hand-added below. Regenerating from the CSVs drops all of it.
-- ---------------------------------------------------------------------------

-- **Two model versions, because two behaviours changed**, and a model version
-- that lags its code makes `semantic_runs` state something untrue.
--
-- `youtube_uploader_tag_resolver` is the row that *records* the restriction
-- being lifted: its parameters said `"concept_kinds": ["creator"]` in so many
-- words. `ontology_first_resolver` is the one in the run identity — `(user,
-- revision, ontology version, resolver, scorer)` — so it is what makes a fresh
-- run happen at all.
--
-- **Retired in the same statement that publishes the successor.** The
-- finalizer picks the newest *active* model, so leaving both active works by
-- ordering, which is a coincidence rather than a statement. Retirement is not
-- deletion: the old row stays and keeps its history.
--
-- **0.2.0 after 0.1.0, even though a 0.6.0 exists under this key**, because
-- there are two lineages here and only one of them is this one: 0.5.0 and
-- 0.6.0 were inserted with `model_role = 'resolver'` and retired when
-- `ontology_first_resolver` took that role at 0.7.0. `initialize_youtube_run_policy`
-- reads `model_role = 'youtube_resolver' and status = 'active' and model_key =
-- 'youtube_uploader_tag_resolver'`, which has only ever matched 0.1.0.
-- Numbering forward from 0.6.0 would claim a continuity with rows of another
-- role that does not exist.
--
-- **That lookup is the reason the retire and the insert are one transaction.**
-- With no active row it falls to its deny-all branch, and
-- `youtube_run_policies_resolver_shape_check` refuses a policy granting a
-- resolution permission while naming no resolver — from a trigger on
-- `semantic_runs`, so it would abort the run insert for *every* source with an
-- error naming a YouTube constraint. Asserted below rather than reasoned
-- about.
update ontology.model_versions set status = 'retired'
 where model_key = 'youtube_uploader_tag_resolver' and status = 'active';

insert into ontology.model_versions (id, model_key, version, model_role, code_hash, parameters, status)
values (
  gen_random_uuid(), 'youtube_uploader_tag_resolver', '0.2.0', 'youtube_resolver', null,
  jsonb_build_object(
    'fuzzy', false,
    'match', 'whole_tag_only',
    'vocabulary', 'ontology.concept_labels',
    'concept_kinds', jsonb_build_array('creator', 'work'),
    'work_vocabulary', 'GAME_TAG_CATALOGUE in aws/worker/resolve.py — a '
      || 'per-lane list, not the ontology''s work aliases, because three of '
      || 'those are ordinary English words minted from music libraries and '
      || 'free text must not reach them',
    'min_tag_length', 3,
    'case_insensitive', true,
    'substring_matching', false,
    'work_reading', 'the same uploader tag is emitted a second time under the '
      || 'role uploader_tag_work with the type hint work, so a game or a film '
      || 'named outright in a channel''s keywords can land. The stored '
      || 'youtube_semantic_kind is uploader_tag for both, so the gate '
      || 'guard_youtube_mapping_fusion derives from the kind is unchanged. A '
      || 'tag matching no work alias resolves to nothing, exactly as it does '
      || 'against creators.'
  ),
  'active'
);

update ontology.model_versions set status = 'retired'
 where model_key = 'ontology_first_resolver' and status = 'active';

insert into ontology.model_versions (id, model_key, version, model_role, code_hash, parameters, status)
select gen_random_uuid(), 'ontology_first_resolver', '0.8.0', 'resolver', null,
       old.parameters || jsonb_build_object(
         'youtube_uploader_tag_works',
         'a work named in a channel''s own keywords becomes a term. Two terms '
         || 'per tag rather than a widened hint, so a creator reading and a '
         || 'work reading stay separable in observation_mappings. An alias '
         || 'that is also an ordinary word is refused when the vocabulary is '
         || 'authored — wow is not an alias of World of Warcraft — because a '
         || 'term in the wrong place is a false claim about a person.'
       ),
       'active'
  from ontology.model_versions old
 where old.model_key = 'ontology_first_resolver' and old.version = '0.7.0';

-- **Scorer 0.14.0 — a subscribed channel asserts the works its keywords name.**
-- The third lever, and the one that decides whether any of the two above show
-- on a page. Its argument is at the head of this file; what belongs here is the
-- parameter, because a later reader looks at the model row and not at a commit
-- message.
update ontology.model_versions set status = 'retired'
 where model_key = 'evidence_weighted_scorer' and status = 'active';

insert into ontology.model_versions (id, model_key, version, model_role, code_hash, parameters, status)
select gen_random_uuid(), 'evidence_weighted_scorer', '0.14.0', 'scorer', null,
       old.parameters || jsonb_build_object(
         'subscribed_work',
         'a work named in a subscribed channel''s own keywords is eligible '
         || 'whatever its strength, as the channel''s own creator already is. '
         || 'One subscription is one lineage at ~0.035 against a work bar of '
         || '0.25 and cannot be accumulated — you cannot subscribe twice — so '
         || 'no action weight reaches it and this is a rule rather than a '
         || 'tuning. Bounded by GAME_TAG_CATALOGUE, which is authored, and by '
         || 'concept_kind = work, which the type hints make exact. It does not '
         || 'reach subject:*, which still has to aggregate across channels: '
         || 'a work is an identification, a subject is an abstraction.'
       ),
       'active'
  from ontology.model_versions old
 where old.model_key = 'evidence_weighted_scorer' and old.version = '0.13.0';

do $$
declare
  v_id uuid;
  game_id uuid;
  block text;
  labels integer;
  actives integer;
  enqueued integer;
begin
  select id into v_id from ontology.versions where status = 'published';

  -- **The concept, and its kind.** A game filed as a `topic` would resolve,
  -- score, and be withheld from Memories by the kind allowlist — the exact
  -- failure this migration exists to end, wearing a different name.
  select c.id into game_id
    from ontology.concepts c
    join ontology.concept_revisions r
      on r.concept_id = c.id and r.ontology_version_id = v_id
   where c.concept_key = 'work:hearthstone' and r.concept_kind = 'work'
     and r.status = 'active';
  if game_id is null then
    raise exception 'work:hearthstone is not an active work in the published version';
  end if;

  -- **The label the lane actually resolves is the key**, not the name.
  -- `GAME_TAG_CATALOGUE` maps the tag `Hearthstone` to `work:hearthstone` and
  -- emits the key; `0149`'s arrangement — every catalogue concept carrying its
  -- own key as an `alternate` label — is what lets the ordinary exact-alias
  -- path match it at 1.000 with no new resolution code. Without this row the
  -- lane resolves to nothing and says so nowhere, which is the failure mode
  -- `work_titles.mjs` names for the catalogue it ships beside.
  --
  -- All three, not only the one this migration is named after: two of them
  -- match nothing on any account measured so far, and a key that resolves to
  -- nothing is exactly what an unexercised path looks like from the outside.
  select count(*) into labels
    from ontology.concept_labels l
    join ontology.concepts c on c.id = l.concept_id
    join ontology.concept_revisions r
      on r.concept_id = c.id and r.ontology_version_id = v_id
   where l.ontology_version_id = v_id and l.status = 'active'
     and l.normalized_label = c.concept_key
     and r.concept_kind = 'work' and r.status = 'active'
     and c.concept_key in ('work:hearthstone', 'work:world_of_warcraft',
                           'work:final_fantasy_xiv');
  if labels <> 3 then
    raise exception
      'expected 3 games carrying their own key as a label, found %', labels;
  end if;

  -- **The abbreviations belong to the lane and to nothing else.** `ffxiv`,
  -- `ff14` and `warcraft` are keys into `GAME_TAG_CATALOGUE`; as *ontology*
  -- aliases they would be reachable by every lane that resolves free text,
  -- which is exactly how `bleach` — an ordinary word and a real alias of a
  -- real work — became the thing that narrowed this lane. Checked against the
  -- built ontology because that is the half a Python test cannot see, and
  -- `0168`'s companion test checks the half this cannot.
  select count(*) into labels
    from ontology.concept_labels l
   where l.ontology_version_id = v_id and l.status = 'active'
     and l.normalized_label in ('ffxiv', 'ff14', 'warcraft', 'wow');
  if labels <> 0 then
    raise exception
      'a games abbreviation is an ontology alias on % row(s); free text can reach it',
      labels;
  end if;

  select semantic_private.concept_block(game_id, v_id) into block;
  if block is distinct from 'hub:games_play' then
    raise exception 'work:hearthstone blocks as % rather than games', block;
  end if;

  -- One active model per key, across all three. Two would make the finalizer's
  -- choice an ordering coincidence rather than a statement.
  select count(*) into actives
    from ontology.model_versions
   where model_key in ('ontology_first_resolver', 'youtube_uploader_tag_resolver',
                       'evidence_weighted_scorer')
     and status = 'active';
  if actives <> 3 then
    raise exception 'expected one active row per model key, found % in total', actives;
  end if;

  -- **The trigger's own lookup, spelled the way the trigger spells it.** Not a
  -- restatement of the check above: that one counts rows by key, this one asks
  -- the question `initialize_youtube_run_policy` asks, including the role. A
  -- successor inserted under the wrong `model_role` would satisfy the count and
  -- leave every future run denied with nothing failing — which is the failure
  -- this codebase already has on record for this exact lookup.
  select count(*) into actives
    from ontology.model_versions
   where model_role = 'youtube_resolver' and status = 'active'
     and model_key = 'youtube_uploader_tag_resolver';
  if actives <> 1 then
    raise exception
      'initialize_youtube_run_policy would find % youtube_resolver rows, not 1',
      actives;
  end if;

  -- **The last statement, and the only thing that makes any of this run.**
  -- Ingestion is the only other thing that enqueues, and it cannot see an
  -- ontology publish or a model activation.
  select semantic_private.enqueue_recompute_on_analysis_change(
           'ontology 0.21.0 + resolver 0.8.0 + scorer 0.14.0: a subscribed '
           || 'channel asserts the works its own keywords name'
         ) into enqueued;
  raise notice '0168: enqueued % recompute job(s)', enqueued;
end;
$$;

commit;
