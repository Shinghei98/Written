#!/usr/bin/env python3
"""The tokenizer/CJK output-budget report: does an item fit its reserve?

## What this answers

The contract packs a batch by

    512 + ceil(1.20 * sum(item_q99_token_estimates)) <= 4096  AND  items <= 4

and reserves `uncalibrated_item_reserve_tokens = 1280` per item until a
measurement exists. That reserve is a guess, and `output_budget` is the
deployment gate that stays shut until somebody measures it — because the reserve
decides how many items fit in a request, and the whole question is whether a
title in Hangul or Han costs more tokens than one in Latin.

**It measures output, not input.** The model echoes surfaces and canonical
labels into a strict `mention_extract_v1` envelope, so the CJK cost lands in the
response, where `max_output_tokens` is 4096 and a truncated response is a failed
extraction (`finish_reason_not_length` is a required gateway check).

## The fixture is synthetic, and that is deliberate

`kpop_cjk_output_stress` is a *stress* fixture. It is built to the measured shape
of the real corpus and **not from it**: a fixture made of real titles would put
one person's library in the repository as plain text, which is precisely what
`ontology-terms.csv` is git-ignored for. Shape, not content.

Measured 2026-08-17 over `semantic_private.observations` (live):

    field              n      with CJK   p99 chars   max chars   p99 CJK   max CJK
    title              3094   30.8%      111         164         15        39
    album              2586   33.1%      65          112         17        25
    primary_performer  3001   13.1%      103         166         6         10

## What is pinned

    model      Qwen/Qwen3.5-9B
    revision   c202236235762e1c871ad0ccb60c8ee5ba337b9a
    tokenizer  sha256 of tokenizer.json at that revision

**The revision is the one this report measured**, which is the only sense in
which a measurement may pin anything. It does not certify that a deployment
serves it — `llm.gateway.revision` is a separate pin and there is no gateway
yet. A deployment loading a different revision invalidates these numbers and
must re-run this.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import pathlib
import statistics
import sys

MODEL_ID = "Qwen/Qwen3.5-9B"
MODEL_REVISION = "c202236235762e1c871ad0ccb60c8ee5ba337b9a"

# From `runtime_config` in the workbook, and re-read rather than remembered.
ENVELOPE_RESERVE = 512
PACKING_HEADROOM = 1.20
MAX_OUTPUT_TOKENS = 4096
MAX_ITEMS_WIRE = 4
UNCALIBRATED_ITEM_RESERVE = 1280
QUANTILE = 0.99

# **Built to the measured shape.** Latin, mixed and CJK-dominant titles in the
# proportion the corpus shows, at the lengths it shows, with the CJK share of a
# string at the p99 the corpus shows. The strings themselves are ordinary
# vocabulary — group names, common title words — not anybody's library.
CJK_TITLE_PARTS = [
    "사랑의", "밤하늘", "봄날의", "너에게", "우리의", "первый",  # Hangul + one Cyrillic
    "夜空の", "君のため", "花火", "約束", "永遠に", "こころ",       # Kana/Kanji
    "夜曲", "青花瓷", "告白氣球", "晴天", "稻香", "彩虹",          # Han
]
LATIN_TITLE_PARTS = [
    "Midnight", "Golden Hour", "Runaway", "Neon", "Paper Hearts",
    "Slow Burn", "Aftertaste", "Gravity", "Static", "Vermilion",
]
DECORATIONS = [
    "", " (feat. {other})", " - Remastered 2019", " (Live at Budokan)",
    " [Instrumental]", " (Special Edition Bonus Track)",
]


def build_fixture(count: int = 400, seed: int = 20260817) -> list[dict[str, str]]:
    """Titles at the corpus's measured length and script distribution.

    Deterministic: a report that cannot be reproduced is an anecdote. `random`
    is seeded rather than avoided, because the shape is what matters and an
    index-derived pattern would correlate length with script.
    """
    import random

    rng = random.Random(seed)
    rows: list[dict[str, str]] = []
    for index in range(count):
        # 31% of titles carry CJK, per the measurement above.
        cjk = rng.random() < 0.31
        parts = CJK_TITLE_PARTS if cjk else LATIN_TITLE_PARTS
        title = " ".join(rng.choice(parts) for _ in range(rng.randint(1, 4)))
        title += rng.choice(DECORATIONS).format(other=rng.choice(parts))
        # The tail matters more than the middle: the p99 is what the formula
        # consumes, so the fixture must actually reach it.
        if rng.random() < 0.02:
            title = (title + " ") * 3
        rows.append({
            "title": title[:164],
            "primary_performer": " ".join(rng.choice(parts) for _ in range(rng.randint(1, 3)))[:166],
            "album": " ".join(rng.choice(parts) for _ in range(rng.randint(1, 3)))[:112],
        })
    return rows


def worst_case_item(row: dict[str, str], item_index: int, mentions: int = 5) -> dict:
    """The largest legal `mention_extract_v1` item for one input row.

    **Every required field, at the count the schema permits**: 5 mentions, each
    with 4 evidence fields, 3 lookup queries and 2 relation hypotheses. The
    reserve has to cover the worst legal response, not the typical one — a
    response that overruns is `finish_reason: length`, which the gateway
    contract refuses outright, so the failure is total rather than degraded.
    """
    surface = row["title"]
    return {
        "item_index": item_index,
        "abstain": False,
        "abstain_reason": None,
        "mentions": [
            {
                "surface": surface[:256],
                "source_field": "title",
                "source_field_index": None,
                "start": 0,
                "end": len(surface),
                "canonical_label_hypothesis": surface[:256],
                "family_hypothesis": "music_recording",
                "mention_role": "work_or_franchise",
                "conversation_worthy": True,
                "evidence_fields": ["title", "primary_performer", "album", "genres"],
                "lookup_queries": [surface[:64], row["primary_performer"][:64],
                                   row["album"][:64]],
                "relation_hypotheses": [
                    {"predicate": "performed_by",
                     "object_label_hypothesis": row["primary_performer"][:256]},
                    {"predicate": "soundtrack_of",
                     "object_label_hypothesis": row["album"][:256]},
                ],
            }
            for _ in range(mentions)
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tokenizer", required=True,
                        help="path to tokenizer.json at the pinned revision")
    parser.add_argument("--mentions", type=int, default=5,
                        help="mentions per item; 5 is the schema maximum")
    parser.add_argument("--json", action="store_true", help="emit machine-readable")
    args = parser.parse_args()

    from tokenizers import Tokenizer

    path = pathlib.Path(args.tokenizer)
    manifest = hashlib.sha256(path.read_bytes()).hexdigest()
    tokenizer = Tokenizer.from_file(str(path))

    rows = build_fixture()
    counts: list[int] = []
    cjk_counts: list[int] = []
    latin_counts: list[int] = []
    for index, row in enumerate(rows):
        item = worst_case_item(row, index, args.mentions)
        # `separators` without spaces: a strict JSON responder emits compact
        # output, and counting pretty-printed JSON would inflate every number.
        encoded = json.dumps(item, ensure_ascii=False, separators=(",", ":"))
        n = len(tokenizer.encode(encoded, add_special_tokens=False).ids)
        counts.append(n)
        has_cjk = any("぀" <= c <= "鿿" or "가" <= c <= "힯"
                      for c in row["title"])
        (cjk_counts if has_cjk else latin_counts).append(n)

    counts.sort()
    q99 = counts[min(len(counts) - 1, math.ceil(QUANTILE * len(counts)) - 1)]
    worst = counts[-1]

    # **The floor, and the ceiling the schema actually permits.**
    #
    # The fixture is built to *observed* lengths — real titles top out near 164
    # characters. The schema permits **256** for `surface`,
    # `canonical_label_hypothesis` and each `object_label_hypothesis`, and a
    # response is legal at that size whether or not the corpus has ever produced
    # one. Measuring only the corpus would report a reserve that holds until the
    # first pathological row arrives, which is the shape of every threshold this
    # project has had to repair.
    def fits(per_item: int, items: int) -> bool:
        return (ENVELOPE_RESERVE + math.ceil(PACKING_HEADROOM * per_item * items)
                <= MAX_OUTPUT_TOKENS) and items <= MAX_ITEMS_WIRE

    def tokens_for(row: dict[str, str]) -> int:
        item = worst_case_item(row, 0, args.mentions)
        return len(tokenizer.encode(
            json.dumps(item, ensure_ascii=False, separators=(",", ":")),
            add_special_tokens=False).ids)

    floor = tokens_for({"title": "a", "primary_performer": "b", "album": "c"})
    schema_max = tokens_for({"title": "가" * 256, "primary_performer": "花" * 256,
                             "album": "の" * 256})

    max_items_q99 = max((i for i in range(1, MAX_ITEMS_WIRE + 1) if fits(q99, i)),
                        default=0)
    max_items_worst = max((i for i in range(1, MAX_ITEMS_WIRE + 1) if fits(worst, i)),
                          default=0)
    reserve_holds = q99 <= UNCALIBRATED_ITEM_RESERVE

    report = {
        "model_id": MODEL_ID,
        "scaffolding_floor_tokens": floor,
        "schema_max_item_tokens": schema_max,
        "schema_max_item_fits_alone": fits(schema_max, 1),
        "model_revision": MODEL_REVISION,
        "tokenizer_manifest_sha256": manifest,
        "fixture": "kpop_cjk_output_stress",
        "fixture_items": len(rows),
        "mentions_per_item": args.mentions,
        "item_tokens_p50": counts[len(counts) // 2],
        "item_tokens_q99": q99,
        "item_tokens_max": worst,
        "cjk_item_tokens_mean": round(statistics.mean(cjk_counts), 1) if cjk_counts else None,
        "latin_item_tokens_mean": round(statistics.mean(latin_counts), 1) if latin_counts else None,
        "cjk_penalty_ratio": (round(statistics.mean(cjk_counts) / statistics.mean(latin_counts), 3)
                              if cjk_counts and latin_counts else None),
        "uncalibrated_item_reserve_tokens": UNCALIBRATED_ITEM_RESERVE,
        "reserve_covers_q99": reserve_holds,
        "max_items_at_q99": max_items_q99,
        "max_items_at_worst_case": max_items_worst,
        "packing_formula": f"{ENVELOPE_RESERVE}+ceil({PACKING_HEADROOM}*sum(q99))<={MAX_OUTPUT_TOKENS} AND items<={MAX_ITEMS_WIRE}",
    }

    if args.json:
        print(json.dumps(report, indent=2))
        return 0 if reserve_holds and max_items_q99 >= 1 else 1

    print(f"model            {MODEL_ID} @ {MODEL_REVISION[:12]}")
    print(f"tokenizer sha256 {manifest}")
    print(f"fixture          kpop_cjk_output_stress, {len(rows)} items, "
          f"{args.mentions} mentions each (schema max)")
    print()
    print(f"item tokens      p50 {report['item_tokens_p50']}  "
          f"q99 {q99}  max {worst}")
    print(f"CJK vs Latin     {report['cjk_item_tokens_mean']} vs "
          f"{report['latin_item_tokens_mean']} mean tokens  "
          f"(ratio {report['cjk_penalty_ratio']})")
    print()
    print(f"scaffolding      {floor} tokens before any content "
          f"({100*floor//max(q99,1)}% of the q99 item)")
    print(f"schema-max item  {schema_max} tokens — fits alone? "
          f"{'YES' if fits(schema_max, 1) else 'NO'}")
    print()
    print(f"reserve {UNCALIBRATED_ITEM_RESERVE}/item covers q99? "
          f"{'YES' if reserve_holds else 'NO'}")
    print(f"items that fit   {max_items_q99} at q99, "
          f"{max_items_worst} at absolute worst case")
    print(f"formula          {report['packing_formula']}")
    return 0 if reserve_holds and max_items_q99 >= 1 else 1


if __name__ == "__main__":
    sys.exit(main())
