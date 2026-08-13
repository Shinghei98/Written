#!/usr/bin/env python3
"""Prefill `ontology-terms.csv` with proposed creator keys, and check them.

    python3 tools/prefill_terms.py                  # report only, writes nothing
    python3 tools/prefill_terms.py --write          # apply the proposals
    python3 tools/prefill_terms.py --lint           # check what is already labelled

**It proposes; the labelling stays yours.** Every proposal lands with an
`auto:` marker in `notes` naming what the tool did and how much it trusted
itself, so the file can be sorted by that column and the risky rows read first.
Clearing the marker is how a row becomes yours; `--lint` counts rows still
carrying one.

**It never overwrites a label.** A row with anything in `concept` is skipped
entirely, so re-running after hand-correcting costs nothing — the same discipline
`export_terms_to_label.py` applies when it carries labels forward.

**The key function is imported, never copied.** `seed_music_from_library.slug`
is the post-`0091` version: NFKD to fold Latin accents, recomposed to NFC so a
Hangul syllable survives the character class, quote styles folded, and a SHA-256
digest — not a constant — where nothing survives. `0091` merged nine Korean
artists into one concept because that fallback was a constant, and a second copy
of this function is how that comes back.

**Splitting, which is the point of the tool.** `English Baroque Soloists,
Monteverdi Choir & John Eliot Gardiner` is three entities, and one row that names
three concepts is how the scorer already reads a credit — `0114` redistributes a
suppressed concept's weight to the *other named roles on the same row*, which
presumes they are separable. So the worksheet's `concept` field takes several
keys joined by `;`.

That is a worksheet convention and deliberately not the ontology's:
`semantic/ontology/seed_aliases.csv` is one row per fact, with no multi-value
field anywhere, and whatever turns these labels into those CSVs must explode the
join into rows. The worksheet keeps them on one line because it is keyed
`(role, term)` and `export_terms_to_label.py` carries labels forward on exactly
that pair — splitting a term into three rows would break the carry-forward and
lose the work on the next distillation.

**A separator is not evidence of a list.** `Earth, Wind & Fire` is one band and
`Simon & Garfunkel` is one act, so risk is reported rather than guessed at:

    list        a comma is present — a credit list, and usually right
    pair        joined only by `&` or `/` — as likely a duo or a band name
    featured    a `feat.`/`ft.`/`with` marker — the tail is a guest
    single      no separator at all

**Collisions are the `0091` defect caught at authoring time.** Two different
names reaching one key means one concept about to hold two people's work, which
is invisible once seeded and expensive to unpick. Reported always, in both
directions, and never written.

The same person appearing as composer *and* performer is not a collision — one
name, one key, two roles — and is excluded by comparing distinct names rather
than distinct rows.
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from seed_music_from_library import slug  # noqa: E402

WORKSHEET = "ontology-terms.csv"
FIELDS = ["role", "term", "n", "resolves_today", "concept", "notes"]

# Composers and performers become `creator:` concepts, and so do YouTube
# channels and uploader tags — `0078`'s resolver is scoped to
# `concept_kinds: ["creator"]`, so a tag that resolves to anything else is a tag
# that resolves to nothing.
#
# **The splitting matters more here than on music.** A channel is often named
# `Artist - Topic` or `NAME OFFICIAL & friends`, and a tag list is already
# atomic; `parts` treats both correctly because it splits on separators rather
# than assuming a credit shape. Tags shorter than `0078`'s `min_tag_length` are
# excluded upstream, at extraction, so nothing here has to know about them.
#
# Albums and titles want `work:` and a judgement this tool has no basis for — an
# album is one work and a dozen artists, and which titles deserve to be works at
# all is the question the work bar (0.25) exists to answer. They are left alone.
CREATOR_ROLES = ("composer", "performer", "yt_channel", "uploader_tag")

JOIN = ";"

# `feat.`/`ft.`/`with` mark a guest rather than a co-credit. Normalised to a
# separator first so the split below does not have to know about them.
FEATURED = re.compile(r"\s+(?:feat\.?|ft\.?|featuring|with)\s+", re.IGNORECASE)
SEPARATORS = re.compile(r"\s*[,;&/]\s*|\s+and\s+", re.IGNORECASE)


def parts(term: str) -> tuple[list[str], str]:
    """Split a credit into names, and say how much to trust the split."""
    featured = bool(FEATURED.search(term))
    text = FEATURED.sub(",", term)
    pieces = [piece.strip() for piece in SEPARATORS.split(text)]
    pieces = [piece for piece in pieces if piece]

    if len(pieces) <= 1:
        return pieces or [term.strip()], "single"
    if featured:
        return pieces, "featured"
    if "," in text:
        return pieces, "list"
    return pieces, "pair"


def load(path: str) -> list[dict]:
    with open(path, encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def save(path: str, rows: list[dict]) -> None:
    # UTF-8 **with a BOM**, as `export_terms_to_label.py` writes it and for the
    # same reason: a third of these terms are CJK and Excel guesses a legacy
    # Western encoding without it.
    with open(path, "w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)


def propose(rows: list[dict]) -> tuple[dict[int, tuple[str, str, list[str]]], dict]:
    """`row index -> (concept, risk, names)` for every unlabelled creator row."""
    proposals: dict[int, tuple[str, str, list[str]]] = {}
    # `key -> {name}`, over proposals *and* existing labels, so a new key
    # colliding with one already hand-written is caught too.
    owners: dict[str, set[str]] = defaultdict(set)

    for index, row in enumerate(rows):
        if row["role"] not in CREATOR_ROLES:
            continue
        existing = (row.get("concept") or "").strip()
        if existing:
            for key in existing.split(JOIN):
                key = key.strip()
                if key:
                    owners[key].add(row["term"].strip())
            continue

        names, risk = parts(row["term"])
        keys = []
        for name in names:
            key = f"creator:{slug(name)}"
            keys.append(key)
            owners[key].add(name)
        proposals[index] = (JOIN.join(keys), risk, names)

    collisions = {key: names for key, names in owners.items() if len(names) > 1}
    return proposals, collisions


QUOTES = str.maketrans("", "", "‘’“”\"'")


def collision_kind(names: set[str]) -> str:
    """Why one key holds several names — which decides whether it is a fault.

    `slug` folds quote style and case *deliberately*: `Amanda “Kiddo” Ibanez`
    and `Amanda "Kiddo" Ibanez` are one person spelled two ways, and so are
    `"Hitman" Bang` and `"hitman"bang`. Those merges are the function working.

    **Case is the one that is not safe, and it is not safe in one direction
    only.** Stylised capitalisation is identity-bearing for a whole class of
    artist — `LiSA` is not `Lisa`, `IZ*ONE` is not `Izone` — while for everybody
    else it is noise. Nothing in the string says which, so a case-only collision
    is the one a person has to rule on.
    """
    stripped = {n.translate(QUOTES).strip() for n in names}
    if len(stripped) == 1:
        return "quote-style"
    if len({n.casefold() for n in stripped}) == 1:
        return "case-only"
    return "distinct"


def report(rows, proposals, collisions, limit: int) -> None:
    by_risk = Counter(risk for _, risk, _ in proposals.values())
    total = sum(by_risk.values())
    print(f"{WORKSHEET}: {len(rows)} rows, {total} creator rows unlabelled\n")

    print(f"{'risk':<10}{'rows':>7}   what it means")
    meaning = {
        "single": "one name, no separator — safe",
        "list":   "a comma is present — a credit list",
        "pair":   "joined only by & or / — CHECK, may be one act",
        "featured": "a guest credit — CHECK the tail",
    }
    for risk in ("single", "list", "pair", "featured"):
        if by_risk.get(risk):
            print(f"{risk:<10}{by_risk[risk]:>7}   {meaning[risk]}")
    print()

    for risk in ("pair", "featured", "list"):
        sample = [(i, p) for i, p in proposals.items() if p[1] == risk]
        if not sample:
            continue
        sample.sort(key=lambda item: -int(rows[item[0]]["n"] or 0))
        print(f"── {risk} ({len(sample)}), by play count:")
        for index, (concept, _, names) in sample[:limit]:
            term = rows[index]["term"]
            print(f"   n={rows[index]['n']:>4}  {term}")
            print(f"          -> {' + '.join(names)}")
        if len(sample) > limit:
            print(f"   … {len(sample) - limit} more")
        print()

    if collisions:
        grouped = defaultdict(list)
        for key, names in collisions.items():
            grouped[collision_kind(names)].append((key, names))

        headline = {
            "case-only": "!! CASE-ONLY — decide these; stylised caps may be identity",
            "distinct":  "!! DISTINCT NAMES — a real merge, must not be seeded",
            "quote-style": "   quote-style — one name spelled two ways; slug folds"
                           " these on purpose",
        }
        for kind in ("distinct", "case-only", "quote-style"):
            if kind not in grouped:
                continue
            print(f"{headline[kind]} ({len(grouped[kind])}):")
            for key, names in sorted(grouped[kind]):
                print(f"   {key}")
                for name in sorted(names):
                    print(f"       {name!r}")
            print()
        if "quote-style" in grouped:
            print("   quote-style rows are written; the rest are held back.\n")
    else:
        print("no collisions\n")


def lint(rows: list[dict]) -> int:
    """Check what is already labelled. Returns a process exit code.

    **Several terms reaching one concept is an alias, not a fault**, and the
    first version of this function called it one — reporting 264 problems of
    which `genre:violin: ['Violin', '小提琴音樂']` was typical. That is precisely
    what `semantic/ontology/seed_aliases.csv` exists to hold: one concept, every
    spelling of it, one row each.

    So many-to-one is only worth a word when **nobody has looked at it yet** —
    a merge that a machine proposed and no person has confirmed. Once the
    `auto:` marker is cleared the merge is a decision, and this stops mentioning
    it.
    """
    problems = warnings = 0
    labelled = [r for r in rows if (r.get("concept") or "").strip()]
    auto = [r for r in labelled if (r.get("notes") or "").startswith("auto:")]
    reviewed: dict[str, set[str]] = defaultdict(set)
    unreviewed: dict[str, set[str]] = defaultdict(set)
    well_formed = re.compile(r"^[a-z_]+:[^\s;]+$")

    for row in labelled:
        is_auto = (row.get("notes") or "").startswith("auto:")
        for key in (row["concept"] or "").split(JOIN):
            key = key.strip()
            if not key:
                continue
            if not well_formed.match(key):
                print(f"malformed key {key!r} on {row['role']} {row['term']!r}")
                problems += 1
            if not is_auto:
                reviewed[key].add(row["term"].strip())

    # **Compare the split names, never the whole term** — the same comparison
    # `propose` makes, and for the same reason. After splitting, one artist
    # legitimately appears in many credits: `陳銳` alone and
    # `陳銳, 瑞典廣播交響樂團 & 丹尼爾・哈汀` both yield `creator:陳銳`, which is the
    # splitting working rather than a merge. Checking whole terms called 235 of
    # those a fault; checking names finds the four that are.
    for row in rows:
        if not (row.get("notes") or "").startswith("auto:"):
            continue
        for name in parts(row["term"])[0]:
            unreviewed[f"creator:{slug(name)}"].add(name)

    for key, names in sorted(unreviewed.items()):
        if len(names) > 1:
            print(f"unconfirmed merge  {key}: {sorted(names)}")
            warnings += 1

    aliased = sum(1 for names in reviewed.values() if len(names) > 1)
    keys = set(reviewed) | set(unreviewed)

    print(f"\n{len(labelled)} labelled, {len(auto)} still carrying an auto: marker")
    print(f"{len(keys)} distinct concept keys, {aliased} of them with several"
          " confirmed spellings")
    if warnings:
        print(f"{warnings} unconfirmed merge(s) — machine-proposed, nobody has"
              " looked yet")
    print("no problems" if not problems else f"{problems} malformed key(s)")
    return 1 if problems else 0


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--write", action="store_true",
                    help="apply the proposals (default is report only)")
    ap.add_argument("--lint", action="store_true",
                    help="check the labels already in the file")
    ap.add_argument("--limit", type=int, default=12,
                    help="rows to show per risk class in the report")
    ap.add_argument("--path", default=WORKSHEET)
    args = ap.parse_args()

    if not os.path.exists(args.path):
        sys.exit(f"{args.path} not found — run tools/export_terms_to_label.py first")

    rows = load(args.path)
    if args.lint:
        sys.exit(lint(rows))

    proposals, collisions = propose(rows)
    report(rows, proposals, collisions, args.limit)

    if not args.write:
        print("nothing written — re-run with --write to apply")
        return

    # A colliding key is never written: the whole point of finding it is that
    # somebody decides, and a file that already contains the merge is a worse
    # place to decide from.
    # A quote-style collision is `slug` doing its job, so those are written. Any
    # other kind is held back: the point of finding a merge is that somebody
    # decides, and a file that already contains it is a worse place to decide
    # from.
    held = {key for key, names in collisions.items()
            if collision_kind(names) != "quote-style"}

    written = skipped = 0
    for index, (concept, risk, _) in proposals.items():
        if any(k.strip() in held for k in concept.split(JOIN)):
            skipped += 1
            continue
        rows[index]["concept"] = concept
        rows[index]["notes"] = f"auto:{risk}"
        written += 1

    save(args.path, rows)
    print(f"wrote {written} proposals to {args.path}")
    if skipped:
        print(f"skipped {skipped} row(s) touching a collision — resolve those by hand")
    print("every one carries an auto: marker; clear it as you confirm the row")


if __name__ == "__main__":
    main()
