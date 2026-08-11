-- **The vocabulary is measured, not invented.** Every alias below occurs in a real
-- Apple Music library — 103 distinct genre strings over 5,046 mentions, read out of
-- `public.distilled_records` where Apple's own `genres` field is stored
-- unencrypted. Authoring from imagination would have produced an English-only list
-- and missed the finding that decides the whole design.
-- 
-- **Apple returns genre names in the storefront's locale, and one library carries
-- both.** `Classical` appears 1,126 times and `古典樂` 314; `Piano` 15 and
-- `鋼琴音樂` 52; `Chamber Music` 20 and `室樂` 33. A concept keyed on the English
-- string alone would silently discard a large share of this person's library — and
-- silently is the operative word, because an abstention looks exactly like a
-- library with nothing in it. `ontology.concept_labels` has a `locale` column for
-- precisely this, so each concept carries its English label and its Traditional
-- Chinese alias as separate rows.
-- 
-- **Three things are deliberately not concepts.** `Music` / `音樂` is Apple's root
-- bucket and the second most common string in the library at 1,195 mentions — it
-- distinguishes nobody. `Worldwide` and `Asia` are storefront geography rather
-- than genre. Admitting any of them would put a concept on almost every track and
-- teach the scorer that everyone is identical.
-- 
-- The normalized labels are computed with `written_ontology.normalize.normalize_text`
-- rather than written by hand, because the resolver compares against exactly that
-- function's output and a hand-typed `k-pop` would never match `k pop`.
-- 
--     python3 tools/seed_music_concepts.py > supabase/migrations/0066_music_concepts.sql

begin;

-- Every concept, its revision and its labels, in one statement per kind so
-- a re-run is a no-op rather than a duplicate. `on conflict do nothing`
-- throughout: this file is expected to be applied twice by the replay.

create temporary table seed_music (
  concept_key text primary key,
  preferred_label text not null,
  broader_key text
) on commit drop;

insert into seed_music (concept_key, preferred_label, broader_key) values
  ('genre:classical', 'Classical', 'hub:music'),
  ('genre:pop', 'Pop', 'hub:music'),
  ('genre:rock', 'Rock', 'hub:music'),
  ('genre:electronic', 'Electronic', 'hub:music'),
  ('genre:jazz', 'Jazz', 'hub:music'),
  ('genre:hip_hop', 'Hip-Hop/Rap', 'hub:music'),
  ('genre:rnb_soul', 'R&B/Soul', 'hub:music'),
  ('genre:country', 'Country', 'hub:music'),
  ('genre:folk', 'Folk', 'hub:music'),
  ('genre:world', 'World', 'hub:music'),
  ('genre:new_age', 'New Age', 'hub:music'),
  ('genre:soundtrack', 'Soundtrack', 'hub:music'),
  ('genre:musicals', 'Musicals', 'hub:music'),
  ('genre:anime', 'Anime', 'hub:music'),
  ('genre:video_game', 'Video Game', 'hub:music'),
  ('genre:holiday', 'Holiday', 'hub:music'),
  ('genre:alternative', 'Alternative', 'hub:music'),
  ('genre:instrumental', 'Instrumental', 'hub:music'),
  ('genre:k_pop', 'K-Pop', 'genre:pop'),
  ('genre:j_pop', 'J-Pop', 'genre:pop'),
  ('genre:mandopop', 'Mandopop', 'genre:pop'),
  ('genre:cantopop', 'Cantopop', 'genre:pop'),
  ('genre:korean_hip_hop', 'Korean Hip-Hop', 'genre:hip_hop'),
  ('genre:adult_contemporary', 'Adult Contemporary', 'genre:pop'),
  ('genre:singer_songwriter', 'Singer/Songwriter', 'hub:music'),
  ('genre:orchestral', 'Orchestral', 'genre:classical'),
  ('genre:chamber_music', 'Chamber Music', 'genre:classical'),
  ('genre:opera', 'Opera', 'genre:classical'),
  ('genre:choral', 'Choral', 'genre:classical'),
  ('genre:sacred', 'Sacred', 'genre:classical'),
  ('genre:cantata', 'Cantata', 'genre:classical'),
  ('genre:oratorio', 'Oratorio', 'genre:classical'),
  ('genre:chant', 'Chant', 'genre:classical'),
  ('genre:art_song', 'Art Song', 'genre:classical'),
  ('genre:solo_instrumental', 'Solo Instrumental', 'genre:classical'),
  ('genre:piano', 'Piano', 'genre:classical'),
  ('genre:violin', 'Violin', 'genre:classical'),
  ('genre:cello', 'Cello', 'genre:classical'),
  ('genre:vocal', 'Vocal', 'genre:classical'),
  ('genre:classical_crossover', 'Classical Crossover', 'genre:classical'),
  ('genre:renaissance', 'Renaissance', 'genre:classical'),
  ('genre:baroque', 'Baroque Era', 'genre:classical'),
  ('genre:high_classical', 'High Classical', 'genre:classical'),
  ('genre:romantic', 'Romantic Era', 'genre:classical'),
  ('genre:impressionist', 'Impressionist', 'genre:classical'),
  ('genre:modern_era', 'Modern Era', 'genre:classical'),
  ('genre:contemporary_classical', 'Contemporary Era', 'genre:classical'),
  ('genre:minimalism', 'Minimalism', 'genre:classical'),
  ('genre:dance', 'Dance', 'hub:music'),
  ('genre:house', 'House', 'genre:electronic'),
  ('genre:techno', 'Techno', 'genre:electronic'),
  ('genre:disco', 'Disco', 'genre:dance'),
  ('genre:electronica', 'Electronica', 'genre:electronic'),
  ('genre:breakbeat', 'Breakbeat', 'genre:electronic'),
  ('genre:soft_rock', 'Soft Rock', 'genre:rock'),
  ('genre:hard_rock', 'Hard Rock', 'genre:rock'),
  ('genre:arena_rock', 'Arena Rock', 'genre:rock'),
  ('genre:folk_rock', 'Folk Rock', 'genre:rock'),
  ('genre:pop_rock', 'Pop/Rock', 'genre:rock'),
  ('genre:mainstream_jazz', 'Mainstream Jazz', 'genre:jazz'),
  ('genre:contemporary_jazz', 'Contemporary Jazz', 'genre:jazz'),
  ('genre:crossover_jazz', 'Crossover Jazz', 'genre:jazz');

create temporary table seed_music_label (
  concept_key text not null,
  label text not null,
  normalized_label text not null,
  locale text not null,
  label_type text not null
) on commit drop;

insert into seed_music_label (concept_key, label, normalized_label, locale, label_type) values
  ('genre:classical', 'Classical', 'classical', 'en', 'preferred'),
  ('genre:classical', '古典樂', '古典樂', 'zh-Hant', 'alternate'),
  ('genre:pop', 'Pop', 'pop', 'en', 'preferred'),
  ('genre:pop', '流行樂', '流行樂', 'zh-Hant', 'alternate'),
  ('genre:rock', 'Rock', 'rock', 'en', 'preferred'),
  ('genre:rock', '搖滾樂', '搖滾樂', 'zh-Hant', 'alternate'),
  ('genre:electronic', 'Electronic', 'electronic', 'en', 'preferred'),
  ('genre:electronic', '電子音樂', '電子音樂', 'zh-Hant', 'alternate'),
  ('genre:jazz', 'Jazz', 'jazz', 'en', 'preferred'),
  ('genre:jazz', '爵士樂', '爵士樂', 'zh-Hant', 'alternate'),
  ('genre:hip_hop', 'Hip-Hop/Rap', 'hip hop rap', 'en', 'preferred'),
  ('genre:hip_hop', '嘻哈', '嘻哈', 'zh-Hant', 'alternate'),
  ('genre:rnb_soul', 'R&B/Soul', 'r b soul', 'en', 'preferred'),
  ('genre:rnb_soul', '節奏藍調', '節奏藍調', 'zh-Hant', 'alternate'),
  ('genre:country', 'Country', 'country', 'en', 'preferred'),
  ('genre:country', '鄉村音樂', '鄉村音樂', 'zh-Hant', 'alternate'),
  ('genre:folk', 'Folk', 'folk', 'en', 'preferred'),
  ('genre:folk', '民謠', '民謠', 'zh-Hant', 'alternate'),
  ('genre:world', 'World', 'world', 'en', 'preferred'),
  ('genre:world', '世界音樂', '世界音樂', 'zh-Hant', 'alternate'),
  ('genre:new_age', 'New Age', 'new age', 'en', 'preferred'),
  ('genre:new_age', '輕音樂', '輕音樂', 'zh-Hant', 'alternate'),
  ('genre:soundtrack', 'Soundtrack', 'soundtrack', 'en', 'preferred'),
  ('genre:soundtrack', 'TV Soundtrack', 'tv soundtrack', 'en', 'alternate'),
  ('genre:soundtrack', '原聲配樂', '原聲配樂', 'zh-Hant', 'alternate'),
  ('genre:soundtrack', '原聲音樂', '原聲音樂', 'zh-Hant', 'alternate'),
  ('genre:musicals', 'Musicals', 'musicals', 'en', 'preferred'),
  ('genre:musicals', '音樂劇', '音樂劇', 'zh-Hant', 'alternate'),
  ('genre:anime', 'Anime', 'anime', 'en', 'preferred'),
  ('genre:anime', '動畫', '動畫', 'zh-Hant', 'alternate'),
  ('genre:video_game', 'Video Game', 'video game', 'en', 'preferred'),
  ('genre:video_game', '電玩音樂', '電玩音樂', 'zh-Hant', 'alternate'),
  ('genre:holiday', 'Holiday', 'holiday', 'en', 'preferred'),
  ('genre:holiday', 'Christmas', 'christmas', 'en', 'alternate'),
  ('genre:holiday', '節慶音樂', '節慶音樂', 'zh-Hant', 'alternate'),
  ('genre:alternative', 'Alternative', 'alternative', 'en', 'preferred'),
  ('genre:alternative', '另類音樂', '另類音樂', 'zh-Hant', 'alternate'),
  ('genre:instrumental', 'Instrumental', 'instrumental', 'en', 'preferred'),
  ('genre:instrumental', '器樂', '器樂', 'zh-Hant', 'alternate'),
  ('genre:k_pop', 'K-Pop', 'k pop', 'en', 'preferred'),
  ('genre:k_pop', '韓國流行樂', '韓國流行樂', 'zh-Hant', 'alternate'),
  ('genre:j_pop', 'J-Pop', 'j pop', 'en', 'preferred'),
  ('genre:j_pop', 'Japanese Pop', 'japanese pop', 'en', 'alternate'),
  ('genre:j_pop', '日本流行樂', '日本流行樂', 'zh-Hant', 'alternate'),
  ('genre:mandopop', 'Mandopop', 'mandopop', 'en', 'preferred'),
  ('genre:mandopop', '國語流行樂', '國語流行樂', 'zh-Hant', 'alternate'),
  ('genre:mandopop', '華語音樂', '華語音樂', 'zh-Hant', 'alternate'),
  ('genre:cantopop', 'Cantopop', 'cantopop', 'en', 'preferred'),
  ('genre:cantopop', 'Cantopop/HK-Pop', 'cantopop hk pop', 'en', 'alternate'),
  ('genre:cantopop', 'HK-Pop', 'hk pop', 'en', 'alternate'),
  ('genre:cantopop', '粵語流行樂', '粵語流行樂', 'zh-Hant', 'alternate'),
  ('genre:korean_hip_hop', 'Korean Hip-Hop', 'korean hip hop', 'en', 'preferred'),
  ('genre:korean_hip_hop', '韓國嘻哈', '韓國嘻哈', 'zh-Hant', 'alternate'),
  ('genre:adult_contemporary', 'Adult Contemporary', 'adult contemporary', 'en', 'preferred'),
  ('genre:adult_contemporary', '成人抒情', '成人抒情', 'zh-Hant', 'alternate'),
  ('genre:singer_songwriter', 'Singer/Songwriter', 'singer songwriter', 'en', 'preferred'),
  ('genre:singer_songwriter', '唱作歌手', '唱作歌手', 'zh-Hant', 'alternate'),
  ('genre:orchestral', 'Orchestral', 'orchestral', 'en', 'preferred'),
  ('genre:orchestral', '管弦樂', '管弦樂', 'zh-Hant', 'alternate'),
  ('genre:orchestral', '中國管弦樂', '中國管弦樂', 'zh-Hant', 'alternate'),
  ('genre:chamber_music', 'Chamber Music', 'chamber music', 'en', 'preferred'),
  ('genre:chamber_music', '室樂', '室樂', 'zh-Hant', 'alternate'),
  ('genre:opera', 'Opera', 'opera', 'en', 'preferred'),
  ('genre:opera', '歌劇專輯', '歌劇專輯', 'zh-Hant', 'alternate'),
  ('genre:choral', 'Choral', 'choral', 'en', 'preferred'),
  ('genre:choral', '合唱', '合唱', 'zh-Hant', 'alternate'),
  ('genre:sacred', 'Sacred', 'sacred', 'en', 'preferred'),
  ('genre:sacred', '聖樂', '聖樂', 'zh-Hant', 'alternate'),
  ('genre:cantata', 'Cantata', 'cantata', 'en', 'preferred'),
  ('genre:cantata', '清唱劇', '清唱劇', 'zh-Hant', 'alternate'),
  ('genre:oratorio', 'Oratorio', 'oratorio', 'en', 'preferred'),
  ('genre:oratorio', '神劇', '神劇', 'zh-Hant', 'alternate'),
  ('genre:chant', 'Chant', 'chant', 'en', 'preferred'),
  ('genre:chant', '素歌', '素歌', 'zh-Hant', 'alternate'),
  ('genre:art_song', 'Art Song', 'art song', 'en', 'preferred'),
  ('genre:art_song', '藝術歌曲', '藝術歌曲', 'zh-Hant', 'alternate'),
  ('genre:solo_instrumental', 'Solo Instrumental', 'solo instrumental', 'en', 'preferred'),
  ('genre:solo_instrumental', '器樂獨奏', '器樂獨奏', 'zh-Hant', 'alternate'),
  ('genre:piano', 'Piano', 'piano', 'en', 'preferred'),
  ('genre:piano', '鋼琴音樂', '鋼琴音樂', 'zh-Hant', 'alternate'),
  ('genre:violin', 'Violin', 'violin', 'en', 'preferred'),
  ('genre:violin', '小提琴音樂', '小提琴音樂', 'zh-Hant', 'alternate'),
  ('genre:cello', 'Cello', 'cello', 'en', 'preferred'),
  ('genre:cello', '大提琴音樂', '大提琴音樂', 'zh-Hant', 'alternate'),
  ('genre:vocal', 'Vocal', 'vocal', 'en', 'preferred'),
  ('genre:vocal', '聲樂', '聲樂', 'zh-Hant', 'alternate'),
  ('genre:classical_crossover', 'Classical Crossover', 'classical crossover', 'en', 'preferred'),
  ('genre:classical_crossover', '古典跨界', '古典跨界', 'zh-Hant', 'alternate'),
  ('genre:renaissance', 'Renaissance', 'renaissance', 'en', 'preferred'),
  ('genre:renaissance', '文藝復興時期', '文藝復興時期', 'zh-Hant', 'alternate'),
  ('genre:baroque', 'Baroque Era', 'baroque era', 'en', 'preferred'),
  ('genre:baroque', '巴洛克音樂', '巴洛克音樂', 'zh-Hant', 'alternate'),
  ('genre:high_classical', 'High Classical', 'high classical', 'en', 'preferred'),
  ('genre:high_classical', '全盛期古典音樂', '全盛期古典音樂', 'zh-Hant', 'alternate'),
  ('genre:romantic', 'Romantic Era', 'romantic era', 'en', 'preferred'),
  ('genre:romantic', '浪漫主義時期作品精選', '浪漫主義時期作品精選', 'zh-Hant', 'alternate'),
  ('genre:romantic', '浪漫時期', '浪漫時期', 'zh-Hant', 'alternate'),
  ('genre:romantic', 'Romantic', 'romantic', 'en', 'alternate'),
  ('genre:impressionist', 'Impressionist', 'impressionist', 'en', 'preferred'),
  ('genre:impressionist', '印象派', '印象派', 'zh-Hant', 'alternate'),
  ('genre:modern_era', 'Modern Era', 'modern era', 'en', 'preferred'),
  ('genre:modern_era', '現代樂派', '現代樂派', 'zh-Hant', 'alternate'),
  ('genre:contemporary_classical', 'Contemporary Era', 'contemporary era', 'en', 'preferred'),
  ('genre:contemporary_classical', '當代音樂', '當代音樂', 'zh-Hant', 'alternate'),
  ('genre:minimalism', 'Minimalism', 'minimalism', 'en', 'preferred'),
  ('genre:minimalism', '極簡主義專輯', '極簡主義專輯', 'zh-Hant', 'alternate'),
  ('genre:dance', 'Dance', 'dance', 'en', 'preferred'),
  ('genre:dance', '舞曲', '舞曲', 'zh-Hant', 'alternate'),
  ('genre:house', 'House', 'house', 'en', 'preferred'),
  ('genre:house', '浩室', '浩室', 'zh-Hant', 'alternate'),
  ('genre:techno', 'Techno', 'techno', 'en', 'preferred'),
  ('genre:techno', '鐵克諾', '鐵克諾', 'zh-Hant', 'alternate'),
  ('genre:disco', 'Disco', 'disco', 'en', 'preferred'),
  ('genre:disco', '迪斯可', '迪斯可', 'zh-Hant', 'alternate'),
  ('genre:electronica', 'Electronica', 'electronica', 'en', 'preferred'),
  ('genre:electronica', '電子舞曲', '電子舞曲', 'zh-Hant', 'alternate'),
  ('genre:breakbeat', 'Breakbeat', 'breakbeat', 'en', 'preferred'),
  ('genre:breakbeat', '碎拍', '碎拍', 'zh-Hant', 'alternate'),
  ('genre:soft_rock', 'Soft Rock', 'soft rock', 'en', 'preferred'),
  ('genre:soft_rock', '軟性搖滾', '軟性搖滾', 'zh-Hant', 'alternate'),
  ('genre:hard_rock', 'Hard Rock', 'hard rock', 'en', 'preferred'),
  ('genre:hard_rock', '硬式搖滾', '硬式搖滾', 'zh-Hant', 'alternate'),
  ('genre:arena_rock', 'Arena Rock', 'arena rock', 'en', 'preferred'),
  ('genre:arena_rock', '體育場搖滾', '體育場搖滾', 'zh-Hant', 'alternate'),
  ('genre:folk_rock', 'Folk Rock', 'folk rock', 'en', 'preferred'),
  ('genre:folk_rock', '民謠搖滾', '民謠搖滾', 'zh-Hant', 'alternate'),
  ('genre:pop_rock', 'Pop/Rock', 'pop rock', 'en', 'preferred'),
  ('genre:pop_rock', '流行搖滾', '流行搖滾', 'zh-Hant', 'alternate'),
  ('genre:mainstream_jazz', 'Mainstream Jazz', 'mainstream jazz', 'en', 'preferred'),
  ('genre:mainstream_jazz', '主流爵士', '主流爵士', 'zh-Hant', 'alternate'),
  ('genre:contemporary_jazz', 'Contemporary Jazz', 'contemporary jazz', 'en', 'preferred'),
  ('genre:contemporary_jazz', '當代爵士樂大賞', '當代爵士樂大賞', 'zh-Hant', 'alternate'),
  ('genre:crossover_jazz', 'Crossover Jazz', 'crossover jazz', 'en', 'preferred'),
  ('genre:crossover_jazz', '跨界爵士', '跨界爵士', 'zh-Hant', 'alternate');

-- **A published ontology version is immutable, so this mints a new one.**
-- Discovered by being refused: `published or retired ontology versions are
-- immutable`. That is the design rather than an obstacle — a version is a frozen
-- artifact that assertions, scores and worker jobs are bound to by id, and
-- adding a concept to one already in use would silently change what an existing
-- score was computed against.
--
-- So `0.2.0` is created as a draft, `0.1.0` is copied into it wholesale, the
-- genres are added, and only then is it published. **The copy is the part that
-- must not be forgotten**: everything in this schema is keyed by
-- `(ontology_version_id, …)`, so a new version that seeded only genres would be
-- an ontology containing no activities, no hubs and no routines — and the
-- HealthKit path would stop resolving with nothing anywhere saying why.
--
-- `finalize_ingestion_run_v031` selects `status = 'published' order by
-- created_at desc`, so publishing is what switches new jobs over. No code
-- changes; already-queued jobs keep the version they were minted with, which is
-- the point of binding it into the payload.
insert into ontology.versions (id, version, parent_version_id, status, description, published_at)
select gen_random_uuid(), '0.2.1', v.id, 'draft',
       'Adds music genres, in English and Traditional Chinese.', null
from ontology.versions v
where v.version = '0.2.0'
on conflict (version) do nothing;

-- Carry 0.1.0 forward. Concepts themselves are version-independent; their
-- revisions, labels and edges are not.
insert into ontology.concept_revisions (
  ontology_version_id, concept_id, preferred_label, concept_kind,
  definition, sensitivity, inference_policy, status, metadata
)
select new_v.id, r.concept_id, r.preferred_label, r.concept_kind,
       r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
from ontology.concept_revisions r
join ontology.versions old_v on old_v.id = r.ontology_version_id and old_v.version = '0.2.0'
cross join (select id from ontology.versions where version = '0.2.1') new_v
on conflict (ontology_version_id, concept_id) do nothing;

insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status, external_ref
)
select new_v.id, l.concept_id, l.label, l.normalized_label, l.locale,
       l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
from ontology.concept_labels l
join ontology.versions old_v on old_v.id = l.ontology_version_id and old_v.version = '0.2.0'
cross join (select id from ontology.versions where version = '0.2.1') new_v
on conflict (ontology_version_id, concept_id, locale, normalized_label, label_type) do nothing;

insert into ontology.concept_edges (
  ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
  confidence, provenance_type, provenance, status
)
select new_v.id, e.subject_concept_id, e.predicate_key, e.object_concept_id,
       e.confidence, e.provenance_type, e.provenance, e.status
from ontology.concept_edges e
join ontology.versions old_v on old_v.id = e.ontology_version_id and old_v.version = '0.2.0'
cross join (select id from ontology.versions where version = '0.2.1') new_v
on conflict do nothing;

-- **`id` is named explicitly here and nowhere else in this file.**
-- `motif_rules` has no default on its primary key while `concept_revisions`,
-- `concept_labels` and `concept_edges` do, so the copy that worked for three
-- tables failed on the fourth with a not-null violation.
insert into ontology.motif_rules (
  id, ontology_version_id, rule_key, evidence_target_concept_id, output_concept_id,
  evidence_predicate_key, output_predicate_key, rule_kind,
  minimum_independence_groups, minimum_strength, configuration, status
)
select gen_random_uuid(), new_v.id, m.rule_key, m.evidence_target_concept_id, m.output_concept_id,
       m.evidence_predicate_key, m.output_predicate_key, m.rule_kind,
       m.minimum_independence_groups, m.minimum_strength, m.configuration, m.status
from ontology.motif_rules m
join ontology.versions old_v on old_v.id = m.ontology_version_id and old_v.version = '0.2.0'
cross join (select id from ontology.versions where version = '0.2.1') new_v
on conflict do nothing;

-- The genre concepts themselves.
insert into ontology.concepts (id, concept_key)
select gen_random_uuid(), s.concept_key from seed_music s
on conflict (concept_key) do nothing;

-- One revision each, on the new draft version.
--
-- `inference_policy = 'inferable'`: a genre is *stated by Apple* on the track,
-- so attaching it is reading rather than inferring — the same distinction that
-- keeps `Ontology.classify` away from YouTube. The `activity:*` concepts are
-- `review_required` because a fitness routine is a claim about a habit built
-- from recurrence; a genre on a song somebody has in their library is not.
--
-- `sensitivity = 'ordinary'`: musical taste is not a protected characteristic.
-- **`genre:sacred`, `genre:chant`, `genre:cantata` and `genre:oratorio` are the
-- ones to watch** — liturgical music is ordinary as *music* and would not be
-- ordinary as a proxy for religious belief, which is why nothing here may reach
-- a surface without the assertion-level permissions doing their own work.
insert into ontology.concept_revisions (
  ontology_version_id, concept_id, preferred_label, concept_kind,
  definition, sensitivity, inference_policy, status, metadata
)
select v.id, c.id, s.preferred_label, 'genre',
       'Music genre as stated by the provider on the track; never inferred from a title.',
       'ordinary', 'inferable', 'active', '{}'::jsonb
from seed_music s
join ontology.concepts c on c.concept_key = s.concept_key
cross join (select id from ontology.versions where version = '0.2.1') v
on conflict (ontology_version_id, concept_id) do nothing;

-- Labels, in both locales.
insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status
)
select v.id, c.id, l.label, l.normalized_label, l.locale,
       l.label_type, 'curated', 1.0, 'active'
from seed_music_label l
join ontology.concepts c on c.concept_key = l.concept_key
cross join (select id from ontology.versions where version = '0.2.1') v
on conflict (ontology_version_id, concept_id, locale, normalized_label, label_type) do nothing;

-- The hierarchy. `broader` is `assertion_safe` and deliberately *not*
-- transitive for inference: K-Pop is narrower than Pop, and the schema declines
-- to walk that chain on its own.
insert into ontology.concept_edges (
  ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
  confidence, provenance_type, provenance, status
)
select v.id, child.id, 'broader', parent.id, 1.0, 'curated',
       '{"source": "music_concepts"}'::jsonb, 'active'
from seed_music s
join ontology.concepts child on child.concept_key = s.concept_key
join ontology.concepts parent on parent.concept_key = s.broader_key
cross join (select id from ontology.versions where version = '0.2.1') v
where s.broader_key is not null
on conflict do nothing;

-- ---------------------------------------------------------------------------

-- **The check that matters is that a Chinese alias resolves.** Everything else
-- here is bookkeeping; this is the one property the migration exists for, and
-- an English-only seed would pass every other assertion while losing a third of
-- a real library.
do $$
declare
  chinese integer;
  roots integer;
begin
  select count(*) into chinese
    from ontology.concept_labels
   where locale = 'zh-Hant' and status = 'active';
  if chinese < 50 then
    raise exception 'expected the Traditional Chinese aliases, found %', chinese;
  end if;

  -- `Music` / `音樂` must never become a *genre*: Apple puts it on almost every
  -- track, so a genre concept carrying it would give every user the same
  -- evidence and separate nobody.
  --
  -- **Scoped to genres, because the first version of this check was not and
  -- fired on `hub:music`** — which has carried the alias `music` since `0.1.0`,
  -- is a hub rather than a genre, and is exactly where these genres now hang
  -- from. Worth knowing rather than fixing: that alias means Apple's root string
  -- resolves to the music hub for anyone with any music at all. It is copied
  -- forward faithfully here, because quietly dropping a label while claiming to
  -- carry a version forward is a worse habit than an over-broad hub.
  select count(*) into roots
    from ontology.concept_labels l
    join ontology.concept_revisions r
      on r.concept_id = l.concept_id and r.ontology_version_id = l.ontology_version_id
   where l.normalized_label in ('music', '音樂') and r.concept_kind = 'genre';
  if roots <> 0 then
    raise exception 'Apple''s root genre was seeded as a genre concept';
  end if;
end
$$;

-- Published last, and only once everything is in it. A draft is writable and a
-- published version is not, so the order here is the whole safety of the
-- operation: seed, check, publish.
--
-- **Exactly one version may be published at a time** —
-- `one_published_ontology_version` is a unique index on `status`, which is what
-- makes `finalize_ingestion_run_v031`'s "latest published" selection
-- unambiguous rather than a race. So publishing `0.2.0` *is* retiring `0.1.0`;
-- they are one operation and the schema refuses to let them be two.
--
-- Retiring is safe here and will not always be: `user_assertions` and
-- `concept_scores` are empty, so nothing is bound to `0.1.0` yet. Once they are
-- not, a version change means deciding what happens to everything scored
-- against the old one, and that decision belongs with whoever makes the next
-- version rather than with this file.
update ontology.versions
   set status = 'retired'
 where version = '0.2.0' and status = 'published';

update ontology.versions
   set status = 'published', published_at = now()
 where version = '0.2.1' and status = 'draft';

commit;
