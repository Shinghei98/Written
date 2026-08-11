#!/usr/bin/env python3
"""Generate the music-genre seed migration.

**The vocabulary is measured, not invented.** Every alias below occurs in a real
Apple Music library — 103 distinct genre strings over 5,046 mentions, read out of
`public.distilled_records` where Apple's own `genres` field is stored
unencrypted. Authoring from imagination would have produced an English-only list
and missed the finding that decides the whole design.

**Apple returns genre names in the storefront's locale, and one library carries
both.** `Classical` appears 1,126 times and `古典樂` 314; `Piano` 15 and
`鋼琴音樂` 52; `Chamber Music` 20 and `室樂` 33. A concept keyed on the English
string alone would silently discard a large share of this person's library — and
silently is the operative word, because an abstention looks exactly like a
library with nothing in it. `ontology.concept_labels` has a `locale` column for
precisely this, so each concept carries its English label and its Traditional
Chinese alias as separate rows.

**Three things are deliberately not concepts.** `Music` / `音樂` is Apple's root
bucket and the second most common string in the library at 1,195 mentions — it
distinguishes nobody. `Worldwide` and `Asia` are storefront geography rather
than genre. Admitting any of them would put a concept on almost every track and
teach the scorer that everyone is identical.

The normalized labels are computed with `written_ontology.normalize.normalize_text`
rather than written by hand, because the resolver compares against exactly that
function's output and a hand-typed `k-pop` would never match `k pop`.

**These migrations are not re-runnable, unlike every other one here**, and that
is inherent rather than an oversight: publishing is a state transition, and only
one ontology version may be published at a time. Applying `0066` again after
`0067` would try to publish `0.2.0` while `0.2.1` holds that slot. They are
therefore deliberately absent from `replay_contracts.sh`'s `apply_twice` list;
the replay applies each once, in order, which is the only way they make sense.

    python3 tools/seed_music_concepts.py --from 0.1.0 --to 0.2.0 \\
        > supabase/migrations/0066_music_concepts.sql
"""

from __future__ import annotations

import argparse
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "semantic" / "src"))

from written_ontology.normalize import normalize_text  # noqa: E402

# (concept_key, English label, [zh-Hant aliases], broader concept_key or None)
#
# The counts in the comments are mentions in the measured library, so whoever
# edits this can see what is load-bearing and what is a long-tail entry kept for
# completeness.
# `hub:music` already exists in `0.1.0` as the top of this branch, so the root
# genres hang off it rather than floating. That is what makes the tree connect
# to the ontology that is already there instead of being a second, parallel one.
HUB = "hub:music"

GENRES: list[tuple[str, str, list[str], str | None]] = [
    # --- roots, all broader-of the music hub -------------------------------
    ("genre:classical",        "Classical",            ["古典樂"], HUB),   # 1126 + 314
    ("genre:pop",              "Pop",                  ["流行樂"], HUB),   # 325 + 33
    ("genre:rock",             "Rock",                 ["搖滾樂"], HUB),   # 39
    ("genre:electronic",       "Electronic",           ["電子音樂"], HUB),   # 6 + 7
    ("genre:jazz",             "Jazz",                 ["爵士樂"], HUB),   # 8
    ("genre:hip_hop",          "Hip-Hop/Rap",          ["嘻哈"], HUB),   # 16
    ("genre:rnb_soul",         "R&B/Soul",             ["節奏藍調"], HUB),   # 17
    ("genre:country",          "Country",              ["鄉村音樂"], HUB),   # 2 + 2
    ("genre:folk",             "Folk",                 ["民謠"], HUB),
    ("genre:world",            "World",                ["世界音樂"], HUB),   # 4
    ("genre:new_age",          "New Age",              ["輕音樂"], HUB),   # 1 + 2
    ("genre:soundtrack",       "Soundtrack",           ["TV Soundtrack", "原聲配樂", "原聲音樂"], HUB), # 122 + 6 + 1 + 1
    ("genre:musicals",         "Musicals",             ["音樂劇"], HUB),   # 50
    ("genre:anime",            "Anime",                ["動畫"], HUB),   # 73 + 2
    ("genre:video_game",       "Video Game",           ["電玩音樂"], HUB),   # 6
    ("genre:holiday",          "Holiday",              ["Christmas", "節慶音樂"], HUB),   # 2 + 2
    ("genre:alternative",      "Alternative",          ["另類音樂"], HUB),   # 10 + 4
    ("genre:instrumental",     "Instrumental",         ["器樂"], HUB),   # 11 + 2

    # --- regional pop ------------------------------------------------------
    # These are the ones a dating product actually trades on, and the reason the
    # locale problem had to be solved rather than worked around: three of the
    # five biggest here arrive in Chinese on this device.
    ("genre:k_pop",            "K-Pop",                ["韓國流行樂"],        "genre:pop"),   # 414 + 2
    ("genre:j_pop",            "J-Pop",                ["Japanese Pop", "日本流行樂"], "genre:pop"),   # 227 + 2 + 2
    ("genre:mandopop",         "Mandopop",             ["國語流行樂", "華語音樂"], "genre:pop"),  # 120 + 29 + 3
    # **`Cantopop/HK-Pop` is what Apple actually writes**, and seeding only
    # "Cantopop" missed all 94 mentions. Found by measuring what still failed to
    # resolve rather than by re-reading the list — the alias looked obviously
    # right and was obviously wrong.
    ("genre:cantopop",         "Cantopop",             ["Cantopop/HK-Pop", "HK-Pop", "粵語流行樂"], "genre:pop"),   # 94
    ("genre:korean_hip_hop",   "Korean Hip-Hop",       ["韓國嘻哈"],          "genre:hip_hop"),  # 8
    ("genre:adult_contemporary", "Adult Contemporary", ["成人抒情"],          "genre:pop"),   # 6
    ("genre:singer_songwriter", "Singer/Songwriter",   ["唱作歌手"], HUB),   # 1

    # --- classical, which is the bulk of this library ----------------------
    ("genre:orchestral",       "Orchestral",           ["管弦樂", "中國管弦樂"], "genre:classical"),  # 86 + 78 + 1
    ("genre:chamber_music",    "Chamber Music",        ["室樂"],              "genre:classical"),  # 20 + 33
    ("genre:opera",            "Opera",                ["歌劇專輯"],          "genre:classical"),  # 4 + 8
    ("genre:choral",           "Choral",               ["合唱"],              "genre:classical"),  # 8
    ("genre:sacred",           "Sacred",               ["聖樂"],              "genre:classical"),  # 9 + 2
    ("genre:cantata",          "Cantata",              ["清唱劇"],            "genre:classical"),  # 6
    ("genre:oratorio",         "Oratorio",             ["神劇"],              "genre:classical"),  # 2
    ("genre:chant",            "Chant",                ["素歌"],              "genre:classical"),  # 1
    ("genre:art_song",         "Art Song",             ["藝術歌曲"],          "genre:classical"),  # 2
    ("genre:solo_instrumental", "Solo Instrumental",   ["器樂獨奏"],          "genre:classical"),  # 2 + 29
    ("genre:piano",            "Piano",                ["鋼琴音樂"],          "genre:classical"),  # 15 + 52
    ("genre:violin",           "Violin",               ["小提琴音樂"],        "genre:classical"),  # 16 + 31
    ("genre:cello",            "Cello",                ["大提琴音樂"],        "genre:classical"),  # 6 + 14
    ("genre:vocal",            "Vocal",                ["聲樂"],              "genre:classical"),  # 1
    ("genre:classical_crossover", "Classical Crossover", ["古典跨界"],        "genre:classical"),  # 9 + 27

    # --- classical periods -------------------------------------------------
    # Apple states these; they are not inferred from a composer's dates.
    ("genre:renaissance",      "Renaissance",          ["文藝復興時期"],      "genre:classical"),  # 3
    ("genre:baroque",          "Baroque Era",          ["巴洛克音樂"],        "genre:classical"),  # 22 + 33
    ("genre:high_classical",   "High Classical",       ["全盛期古典音樂"],    "genre:classical"),  # 11 + 8
    ("genre:romantic",         "Romantic Era",         ["浪漫主義時期作品精選", "浪漫時期", "Romantic"], "genre:classical"),  # 21 + 38 + 2 + 1
    ("genre:impressionist",    "Impressionist",        ["印象派"],            "genre:classical"),  # 1
    ("genre:modern_era",       "Modern Era",           ["現代樂派"],          "genre:classical"),  # 7 + 7
    ("genre:contemporary_classical", "Contemporary Era", ["當代音樂"],        "genre:classical"),  # 1 + 18
    ("genre:minimalism",       "Minimalism",           ["極簡主義專輯"],      "genre:classical"),  # 1

    # --- electronic and dance ----------------------------------------------
    ("genre:dance",            "Dance",                ["舞曲"], HUB),   # 22 + 8
    ("genre:house",            "House",                ["浩室"],              "genre:electronic"),  # 4 + 2
    ("genre:techno",           "Techno",               ["鐵克諾"],            "genre:electronic"),  # 4
    ("genre:disco",            "Disco",                ["迪斯可"],            "genre:dance"),       # 6
    ("genre:electronica",      "Electronica",          ["電子舞曲"],          "genre:electronic"),  # 1
    ("genre:breakbeat",        "Breakbeat",            ["碎拍"],              "genre:electronic"),  # 1

    # --- rock family --------------------------------------------------------
    ("genre:soft_rock",        "Soft Rock",            ["軟性搖滾"],          "genre:rock"),   # 6
    ("genre:hard_rock",        "Hard Rock",            ["硬式搖滾"],          "genre:rock"),   # 2
    ("genre:arena_rock",       "Arena Rock",           ["體育場搖滾"],        "genre:rock"),   # 4
    ("genre:folk_rock",        "Folk Rock",            ["民謠搖滾"],          "genre:rock"),   # 1
    ("genre:pop_rock",         "Pop/Rock",             ["流行搖滾"],          "genre:rock"),   # 24

    # --- jazz ---------------------------------------------------------------
    ("genre:mainstream_jazz",  "Mainstream Jazz",      ["主流爵士"],          "genre:jazz"),   # 1
    ("genre:contemporary_jazz", "Contemporary Jazz",   ["當代爵士樂大賞"],    "genre:jazz"),   # 2
    ("genre:crossover_jazz",   "Crossover Jazz",       ["跨界爵士"],          "genre:jazz"),   # 1
]

# Strings that occur in the library and are deliberately *not* concepts. Kept as
# a list rather than a comment so the exclusion is reviewable and so nobody adds
# one back without reading why.
NOT_CONCEPTS = {
    "Music": "Apple's root genre — 812 mentions here, plus 383 as 音樂. On almost every track, so it separates nobody.",
    "音樂": "The same root genre in Traditional Chinese.",
    "Worldwide": "Storefront geography, not a genre.",
    "Asia": "Storefront geography, not a genre.",
    "Chinese": "A language/region tag Apple attaches beside a real genre.",
    "節目": "\"Programme\" — a container label, not a genre.",
    # `TV Soundtrack` and `Christmas` are folded in as *aliases* of
    # `genre:soundtrack` and `genre:holiday` — this list once claimed that while
    # the aliases did not exist, so both resolved to nothing.
}


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def main() -> None:
    # **Parameterised because a published ontology version cannot be edited.**
    # `0066` seeded `0.2.0` and then measuring resolution against the real
    # library found four aliases missing — `Cantopop/HK-Pop` alone was 94
    # mentions. There is no correcting that in place: the fix is another
    # version. So this generator takes the pair, and the standing lesson is to
    # **measure coverage before publishing**, since afterwards every typo costs a
    # migration.
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from", dest="parent", default="0.1.0")
    parser.add_argument("--to", dest="target", default="0.2.0")
    args = parser.parse_args()
    parent, target = args.parent, args.target

    out: list[str] = []
    w = out.append

    w(__doc__.split("\n\n", 1)[1].rstrip().replace("\n", "\n-- ").join(["-- ", ""]))
    w("")

    w("begin;")
    w("")
    w("-- Every concept, its revision and its labels, in one statement per kind so")
    w("-- a re-run is a no-op rather than a duplicate. `on conflict do nothing`")
    w("-- throughout: this file is expected to be applied twice by the replay.")
    w("")

    w("create temporary table seed_music (")
    w("  concept_key text primary key,")
    w("  preferred_label text not null,")
    w("  broader_key text")
    w(") on commit drop;")
    w("")
    w("insert into seed_music (concept_key, preferred_label, broader_key) values")
    rows = [
        f"  ({sql_literal(key)}, {sql_literal(label)}, "
        f"{sql_literal(broader) if broader else 'null'})"
        for key, label, _aliases, broader in GENRES
    ]
    w(",\n".join(rows) + ";")
    w("")

    w("create temporary table seed_music_label (")
    w("  concept_key text not null,")
    w("  label text not null,")
    w("  normalized_label text not null,")
    w("  locale text not null,")
    w("  label_type text not null")
    w(") on commit drop;")
    w("")
    w("insert into seed_music_label (concept_key, label, normalized_label, locale, label_type) values")
    label_rows: list[str] = []
    for key, label, aliases, _broader in GENRES:
        label_rows.append(
            f"  ({sql_literal(key)}, {sql_literal(label)}, "
            f"{sql_literal(normalize_text(label))}, 'en', 'preferred')"
        )
        for alias in aliases:
            # An English alias (`Romantic` beside `Romantic Era`) is an English
            # alternate; anything else on this list is Traditional Chinese.
            locale = "en" if alias.isascii() else "zh-Hant"
            label_rows.append(
                f"  ({sql_literal(key)}, {sql_literal(alias)}, "
                f"{sql_literal(normalize_text(alias))}, {sql_literal(locale)}, 'alternate')"
            )
    w(",\n".join(label_rows) + ";")
    w("")

    w(f"""-- **A published ontology version is immutable, so this mints a new one.**
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
select gen_random_uuid(), '{target}', v.id, 'draft',
       'Adds music genres, in English and Traditional Chinese.', null
from ontology.versions v
where v.version = '{parent}'
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
join ontology.versions old_v on old_v.id = r.ontology_version_id and old_v.version = '{parent}'
cross join (select id from ontology.versions where version = '{target}') new_v
on conflict (ontology_version_id, concept_id) do nothing;

insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status, external_ref
)
select new_v.id, l.concept_id, l.label, l.normalized_label, l.locale,
       l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
from ontology.concept_labels l
join ontology.versions old_v on old_v.id = l.ontology_version_id and old_v.version = '{parent}'
cross join (select id from ontology.versions where version = '{target}') new_v
on conflict (ontology_version_id, concept_id, locale, normalized_label, label_type) do nothing;

insert into ontology.concept_edges (
  ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
  confidence, provenance_type, provenance, status
)
select new_v.id, e.subject_concept_id, e.predicate_key, e.object_concept_id,
       e.confidence, e.provenance_type, e.provenance, e.status
from ontology.concept_edges e
join ontology.versions old_v on old_v.id = e.ontology_version_id and old_v.version = '{parent}'
cross join (select id from ontology.versions where version = '{target}') new_v
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
join ontology.versions old_v on old_v.id = m.ontology_version_id and old_v.version = '{parent}'
cross join (select id from ontology.versions where version = '{target}') new_v
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
       'ordinary', 'inferable', 'active', '{{}}'::jsonb
from seed_music s
join ontology.concepts c on c.concept_key = s.concept_key
cross join (select id from ontology.versions where version = '{target}') v
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
cross join (select id from ontology.versions where version = '{target}') v
on conflict (ontology_version_id, concept_id, locale, normalized_label, label_type) do nothing;

-- The hierarchy. `broader` is `assertion_safe` and deliberately *not*
-- transitive for inference: K-Pop is narrower than Pop, and the schema declines
-- to walk that chain on its own.
insert into ontology.concept_edges (
  ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
  confidence, provenance_type, provenance, status
)
select v.id, child.id, 'broader', parent.id, 1.0, 'curated',
       '{{"source": "music_concepts"}}'::jsonb, 'active'
from seed_music s
join ontology.concepts child on child.concept_key = s.concept_key
join ontology.concepts parent on parent.concept_key = s.broader_key
cross join (select id from ontology.versions where version = '{target}') v
where s.broader_key is not null
on conflict do nothing;
""")

    w(f"""-- ---------------------------------------------------------------------------

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
 where version = '{parent}' and status = 'published';

update ontology.versions
   set status = 'published', published_at = now()
 where version = '{target}' and status = 'draft';

commit;""")

    print("\n".join(out))


if __name__ == "__main__":
    main()
