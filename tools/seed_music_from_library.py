#!/usr/bin/env python3
"""Generate an ontology version from a real library, using the music dictionary.

    SUPABASE_SECRET_KEY=... python3.14 tools/seed_music_from_library.py \
        --from 0.2.1 --to 0.3.0 > supabase/migrations/00NN_music_library.sql

The genres already exist (`0066`/`0067`). This adds what the dictionary can now
read that the ontology cannot yet hold: the artists, the works they were written
for, and the eras they belong to — plus the edges that connect them.

**Nothing here is invented.** Every concept comes from a string Apple wrote or a
name somebody recognised, put through `music_dictionary`: credits split, junk
dropped, each name in its own language, genres in English. An artist's genres and
era are *read* from that artist's own rows rather than asserted — Apple states a
genre on 711 of 741 artists and a release date on 710.

**The privacy shape is worth stating, because it changes with scale.** Seeding
concepts from one person's library makes the ontology a description of that
library. For a single curated instance that is exactly the intent — a person
chose this vocabulary. It is *not* the automatic path: `EmergentTermMiner`
requires five distinct users before a term may become a concept, and that floor
exists so a concept named after an obscure artist cannot identify the only person
who listens to them. Anything grown from users rather than curated must go
through the miner.

Needs Python 3.11+ for `written_ontology`; see `export_terms_to_label.py`.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import hashlib
import unicodedata
import urllib.error
import urllib.request
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "semantic", "src"))

from music_dictionary import GENRE_TRANSLATIONS  # noqa: E402
from music_works import (  # noqa: E402
    artist_eras,
    english_genre,
    composers_in,
    people_in,
    propagate,
    resolve_name,
    split_credits,
    normalized_song_key,
    work_for,
    work_parents,
)
from seed_music_concepts import GENRES  # noqa: E402

PROJECT_REF = "fwnezkbesjoazlpaflbq"
BASE = f"https://{PROJECT_REF}.supabase.co"
PAGE = 1000

# **A genre has to be an artist's, not a track's.** One orchestral remix should
# not make a K-pop group classical. A quarter of an artist's rows is low enough
# to keep a genuine second genre and high enough to drop a stray one; it is a
# judgement, and it is the only number here that is.
GENRE_SHARE = 0.25

# Apple's root bucket and its storefront geography never become edges: they sit
# on almost every track and would connect every artist to the same concept.
NOT_A_GENRE = {"Music", "Worldwide", "Asia", "Chinese"}


def env_key() -> str:
    key = os.environ.get("SUPABASE_SECRET_KEY", "").strip()
    if not key:
        sys.exit("SUPABASE_SECRET_KEY is not set.")
    if not re.fullmatch(r"(sb_secret_|sbp_)[A-Za-z0-9_\-]+", key):
        sys.exit(
            "SUPABASE_SECRET_KEY does not look like a Supabase key — a missing "
            "space before the interpreter is the usual cause."
        )
    return key


# **Rows that are not acts, and therefore not vocabulary.**
#
# The pipeline gives `recommendation` an `action_weight` of exactly 0.000 —
# Apple suggesting an album is not something anybody did — and
# `apple_music_subscription` is a fact about an account rather than an act at
# all. Both were nevertheless being read for concept *names*, so the ontology
# was defining its vocabulary from rows it refuses to count as evidence.
#
# Measured on one library: **22 of 38 `work:` concepts had never once been
# accepted onto an observation.** `work:re_zero_starting_life_in_another_world`
# is the clearest — its name comes from *"Netsuretsu! Anison Spirits… TV Anime
# Series Re:ZERO Starting Life in Another World - EP"*, a recommendation, and
# `WORK_EN_SERIES_PATTERN` duly matched it. Attack on Titan, Demon Slayer, My
# Neighbour Totoro and Mob Psycho 100 arrived the same way: works Apple thought
# somebody might like, minted as concepts describing them.
#
# It costs nothing directly — an unmatched concept scores nothing — but it makes
# a count of concepts a claim about coverage that is not true, and it is
# incoherent: a row cannot be worth zero as evidence and authoritative as a
# name.
#
# **Named exclusions rather than an allowlist**, unlike the Memories surface
# filter. There the risk is an internal kind appearing on somebody's profile,
# invisible to them; here the risk is a genuinely act-bearing type being dropped
# from the vocabulary, which loses real concepts. So a new data type is included
# by default and `fetch` prints what it dropped, so a new *non*-act announces
# itself in the output rather than in a count nobody checks.
NOT_AN_ACT = frozenset({"recommendation", "apple_music_subscription"})


def fetch(key: str) -> list[dict]:
    rows: list[dict] = []
    dropped: dict[str, int] = {}
    offset = 0
    while True:
        request = urllib.request.Request(
            f"{BASE}/rest/v1/distilled_records"
            "?select=name,creator,extra,data_type&source=in.(apple_music,music_library)"
            f"&limit={PAGE}&offset={offset}",
            method="GET",
        )
        request.add_header("apikey", key)
        request.add_header("Authorization", f"Bearer {key}")
        try:
            with urllib.request.urlopen(request) as response:
                page = json.loads(response.read() or b"[]")
        except urllib.error.HTTPError as error:
            sys.exit(f"fetch failed: {error.code}\n{error.read().decode()}")
        for row in page:
            data_type = row.get("data_type") or ""
            if data_type in NOT_AN_ACT:
                dropped[data_type] = dropped.get(data_type, 0) + 1
                continue
            rows.append(row)
        if len(page) < PAGE:
            # **Said out loud, per this project's own rule against silent caps.**
            # A filter that quietly halves its input reads as a smaller library,
            # and the whole point of this one is that somebody should be able to
            # see which rows stopped defining vocabulary.
            for data_type, count in sorted(dropped.items(), key=lambda kv: -kv[1]):
                print(f"skipped {count} {data_type} row(s): not an act")
            return rows
        offset += PAGE


def slug(text: str) -> str:
    """A stable handle for a concept key.

    ASCII where the name is Latin, and the characters themselves where it is not:
    `creator:久石讓` is readable and unambiguous, while a hash would be neither.
    The original strings survive as labels either way — the key is only a handle.
    """
    folded = unicodedata.normalize("NFKD", text.strip().casefold())
    folded = "".join(c for c in folded if not unicodedata.combining(c))
    # **Recomposed, and this is the whole of a real bug.** NFKD decomposes a
    # Hangul syllable into jamo — 류 becomes ᄅ + ᅲ — and the class below accepts
    # only *precomposed* syllables `가-힯`. So every Korean name stripped to
    # nothing and fell through to the constant fallback, which merged four
    # different people into `creator:unnamed`: 류정한, 서정아, 김도연 and a
    # decorative-Unicode name, all one concept, all one another's work.
    #
    # NFKD is still wanted for the Latin path — it is what turns `é` into `e`
    # after the combining mark is dropped — so the fix is to recompose
    # afterwards rather than to stop decomposing.
    folded = unicodedata.normalize("NFC", folded)
    # **Quote style must never make two concepts.** `Amanda “Kiddo” Ibanez` and
    # `Amanda "Kiddo" Ibanez` differ by one curly quote, and `"Hitman" Bang` and
    # `"hitman"bang` by case and a space. Folding them here merges the key while
    # rule 6 keeps every spelling as a label.
    folded = folded.replace("\u2018", "").replace("\u2019", "")
    folded = folded.replace("\u201c", "").replace("\u201d", "").replace('"', "")
    keyed = re.sub(r"[^a-z0-9぀-ヿ㐀-鿿가-힯]+", "_", folded).strip("_")
    if keyed:
        return keyed
    # **A constant fallback is a merge waiting to happen.** Any two names the
    # class cannot represent — Yi syllables, emoji, symbol fonts — collapsed onto
    # one key and became one artist. A digest of the original keeps them apart
    # and keeps the key stable across runs, which is what a handle has to be.
    # Unreadable, but a key nobody can read is better than a key that is wrong:
    # the original string survives as the label either way.
    return "x" + hashlib.sha256(text.strip().casefold().encode()).hexdigest()[:12]


def genre_keys() -> dict[str, str]:
    """`English genre -> concept key`, from the genres `0066` already seeded."""
    keys: dict[str, str] = {}
    for concept_key, label, aliases, _broader in GENRES:
        for name in [label, *aliases]:
            keys[english_genre(name)] = concept_key
            keys[name] = concept_key
    return keys


def build(rows: list[dict]) -> tuple[dict, set]:
    """Every concept and edge this library supports.

    Concepts are `{key: {"kind", "label", "aliases"}}`; edges are
    `(subject, "broader", object)`.
    """
    flat = []
    for row in rows:
        extra = row.get("extra") or {}
        if not isinstance(extra, dict):
            extra = {}
        genres = [
            english_genre(g.strip())
            for g in (extra.get("genres") or "").split("|")
            if g.strip()
        ]
        flat.append({
            "title": row.get("name") or "",
            "album": extra.get("album") or "",
            "performer": row.get("creator") or "",
            "composer": extra.get("composer") or "",
            "genres": genres,
            "released": extra.get("released") or "",
        })

    works_by_song = propagate(flat)
    by_performer: dict[str, list[dict]] = defaultdict(list)
    for item in flat:
        if item["performer"]:
            by_performer[item["performer"]].append(item)

    concepts: dict[str, dict] = {}
    edges: set[tuple[str, str, str]] = set()
    genres_of: dict[str, list[str]] = genre_keys()

    def add(key: str, kind: str, label: str) -> None:
        entry = concepts.setdefault(
            key, {"kind": kind, "label": label, "aliases": set()})
        entry["aliases"].add(label)

    # --- people -----------------------------------------------------------
    # A person's genres and era come from their own rows, so credits are
    # attributed before either is counted.
    rows_of_person: dict[str, list[dict]] = defaultdict(list)
    label_of: dict[str, str] = {}
    for item in flat:
        for field in ("performer", "composer"):
            # Composers are capped at three; performers are not. A performer
            # list is who is on the record, and all of them are subjects.
            names = (composers_in if field == "composer" else people_in)(item[field])
            for person in names:
                key = f"creator:{slug(person)}"
                add(key, "creator", person)
                # **The source spelling is kept as a label too.** Resolution does
                # not need it — a term passes through the dictionary before it is
                # matched — but without it the ontology cannot be read on its own:
                # nobody looking at `creator:jean_sibelius` would see that
                # `尚・西貝流士` is in this library under that name.
                if item[field].strip() and item[field].strip() != person:
                    for raw in split_credits(item[field]):
                        if resolve_name(raw) == person and raw != person:
                            add(key, "creator", raw)
                label_of.setdefault(key, person)
                rows_of_person[key].append(item)

    for key, items in rows_of_person.items():
        counted: dict[str, int] = defaultdict(int)
        for item in items:
            for genre in set(item["genres"]):
                if genre and genre not in NOT_A_GENRE:
                    counted[genre] += 1
        for genre, n in counted.items():
            if n / len(items) < GENRE_SHARE:
                continue
            target = genres_of.get(genre)
            if target:
                edges.add((key, "broader", target))

        # The era of the person, not of any one row: `artist_eras` is what knows
        # a compilation's date describes a release rather than a career.
        for era in artist_eras(label_of[key], items):
            add(era, "topic", era.removeprefix("era:"))
            edges.add((key, "broader", era))

    # --- works ------------------------------------------------------------
    for item in flat:
        work = works_by_song.get(
            normalized_song_key(item["title"], item["performer"])
        ) or work_for(item["title"], item["album"], item["genres"], item["performer"])
        if not work:
            continue
        key = f"work:{slug(work)}"
        add(key, "work", work)
        for parent in work_parents(work):
            parent_key = f"work:{slug(parent)}"
            add(parent_key, "work", parent)
            edges.add((key, "broader", parent_key))
        # A work belongs under the genre its own rows carry — the anime OP is
        # anime, the cast recording is a musical.
        for genre in set(item["genres"]):
            target = genres_of.get(genre)
            if target and genre not in NOT_A_GENRE:
                edges.add((key, "broader", target))

    return concepts, edges


def literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from", dest="parent", required=True)
    parser.add_argument("--to", dest="target", required=True)
    args = parser.parse_args()

    rows = fetch(env_key())
    concepts, edges = build(rows)

    from written_ontology.normalize import normalize_text

    out: list[str] = []
    w = out.append
    kinds = defaultdict(int)
    for entry in concepts.values():
        kinds[entry["kind"]] += 1

    w(f"""-- Music concepts read out of one real library.
--
-- Generated by `tools/seed_music_from_library.py --from {args.parent} --to {args.target}`.
-- Do not hand-edit: change `tools/music_dictionary.py` and regenerate, or the
-- file and the rules it came from stop agreeing.
--
-- {len(concepts)} concepts """ + ", ".join(
        f"{n} {kind}" for kind, n in sorted(kinds.items())) + f"""
-- {len(edges)} edges
--
-- **Nothing here is invented.** Every concept is a string Apple wrote or a name
-- somebody recognised, put through the dictionary: credits split, junk dropped,
-- each name in its own language, genres in English. An artist's genres and era
-- are read from that artist's own rows.
--
-- A published ontology version is immutable, so this mints {args.target} from
-- {args.parent}, copies it forward wholesale, adds the above, and publishes last
-- — publishing is also retiring, since only one version may be published.

begin;
""")

    w(f"""insert into ontology.versions (id, version, parent_version_id, status, description, published_at)
select gen_random_uuid(), '{args.target}', v.id, 'draft',
       'Artists, works and eras read from a real Apple Music library.', null
from ontology.versions v where v.version = '{args.parent}'
on conflict (version) do nothing;
""")

    for table, columns, extra in (
        ("concept_revisions",
         "concept_id, preferred_label, concept_kind, definition, sensitivity, "
         "inference_policy, status, metadata",
         "r.concept_id, r.preferred_label, r.concept_kind, r.definition, "
         "r.sensitivity, r.inference_policy, r.status, r.metadata"),
        ("concept_labels",
         "concept_id, label, normalized_label, locale, label_type, "
         "provenance_type, confidence, status, external_ref",
         "l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, "
         "l.provenance_type, l.confidence, l.status, l.external_ref"),
        ("concept_edges",
         "subject_concept_id, predicate_key, object_concept_id, confidence, "
         "provenance_type, provenance, status",
         "e.subject_concept_id, e.predicate_key, e.object_concept_id, "
         "e.confidence, e.provenance_type, e.provenance, e.status"),
    ):
        alias = table[8]
        w(f"""insert into ontology.{table} (ontology_version_id, {columns})
select new_v.id, {extra}
from ontology.{table} {alias}
join ontology.versions old_v on old_v.id = {alias}.ontology_version_id
 and old_v.version = '{args.parent}'
cross join (select id from ontology.versions where version = '{args.target}') new_v
on conflict do nothing;
""")

    w("""insert into ontology.motif_rules (
  id, ontology_version_id, rule_key, evidence_target_concept_id, output_concept_id,
  evidence_predicate_key, output_predicate_key, rule_kind,
  minimum_independence_groups, minimum_strength, configuration, status)
select gen_random_uuid(), new_v.id, m.rule_key, m.evidence_target_concept_id,
       m.output_concept_id, m.evidence_predicate_key, m.output_predicate_key,
       m.rule_kind, m.minimum_independence_groups, m.minimum_strength,
       m.configuration, m.status
from ontology.motif_rules m
join ontology.versions old_v on old_v.id = m.ontology_version_id"""
      f" and old_v.version = '{args.parent}'\n"
      f"cross join (select id from ontology.versions where version = '{args.target}') new_v\n"
      "on conflict do nothing;\n")

    w("create temporary table seed_concept (concept_key text primary key,"
      " preferred_label text not null, concept_kind text not null) on commit drop;")
    w("insert into seed_concept values")
    w(",\n".join(
        f"  ({literal(key)}, {literal(entry['label'])}, {literal(entry['kind'])})"
        for key, entry in sorted(concepts.items())) + ";\n")

    w("create temporary table seed_label (concept_key text, label text,"
      " normalized_label text) on commit drop;")
    labels = [
        (key, alias, normalize_text(alias))
        for key, entry in sorted(concepts.items())
        for alias in sorted(entry["aliases"])
        if normalize_text(alias)
    ]
    w("insert into seed_label values")
    w(",\n".join(
        f"  ({literal(k)}, {literal(a)}, {literal(n)})" for k, a, n in labels) + ";\n")

    w("create temporary table seed_edge (subject_key text, object_key text)"
      " on commit drop;")
    w("insert into seed_edge values")
    w(",\n".join(
        f"  ({literal(s)}, {literal(o)})" for s, _p, o in sorted(edges)) + ";\n")

    w(f"""insert into ontology.concepts (id, concept_key)
select gen_random_uuid(), s.concept_key from seed_concept s
on conflict (concept_key) do nothing;

-- `inference_policy = 'inferable'`: every one of these is *stated* by the
-- source — the performer Apple credited, the genre it labelled, the work it
-- named. Reading is not inferring, which is the same distinction that keeps
-- `Ontology.classify` away from YouTube.
insert into ontology.concept_revisions (
  ontology_version_id, concept_id, preferred_label, concept_kind,
  definition, sensitivity, inference_policy, status, metadata)
select v.id, c.id, s.preferred_label, s.concept_kind,
       'Read from a music library; never inferred from a title.',
       'ordinary', 'inferable', 'active', '{{}}'::jsonb
from seed_concept s
join ontology.concepts c on c.concept_key = s.concept_key
cross join (select id from ontology.versions where version = '{args.target}') v
on conflict (ontology_version_id, concept_id) do nothing;

-- **Two spellings of one name become one concept with two labels.** That is how
-- `Jean Sibelius` and `尚・西貝流士` merge, both being in this library.
insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status)
select v.id, c.id, l.label, l.normalized_label, 'und',
       'alternate', 'curated', 1.0, 'active'
from seed_label l
join ontology.concepts c on c.concept_key = l.concept_key
cross join (select id from ontology.versions where version = '{args.target}') v
on conflict (ontology_version_id, concept_id, locale, normalized_label, label_type)
  do nothing;

insert into ontology.concept_edges (
  ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
  confidence, provenance_type, provenance, status)
select v.id, subject.id, 'broader', object.id, 1.0, 'curated',
       '{{"source": "music_library"}}'::jsonb, 'active'
from seed_edge e
join ontology.concepts subject on subject.concept_key = e.subject_key
join ontology.concepts object on object.concept_key = e.object_key
cross join (select id from ontology.versions where version = '{args.target}') v
on conflict do nothing;

update ontology.versions set status = 'retired'
 where version = '{args.parent}' and status = 'published';

update ontology.versions set status = 'published', published_at = now()
 where version = '{args.target}' and status = 'draft';

commit;
""")

    print("\n".join(out))
    print(
        f"-- {len(concepts)} concepts, {len(labels)} labels, {len(edges)} edges",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
