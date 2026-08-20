#!/usr/bin/env python3
"""Candidate tokenizer exploration for the output budget. **Not a gate pass.**

## What this is, and what it is not

The `output_budget` deployment gate needs a measurement of how many
`mention_extract` items fit one response. This program produces **exploratory
evidence toward that** and deliberately exits non-zero: passing the gate
additionally requires a deployed gateway attesting the same model, tokenizer and
contract, plus a tested overflow route. Neither exists.

**The first version of this program was wrong in ways that mattered**, and the
repairs are the reason for most of what follows:

  * its fixture was **invalid against the schema it claimed to measure** —
    `evidence_fields` carried `primary_performer`, `album` and `genres` where the
    enum permits only `title`, `channel_label`, `description_excerpt`, `tags`;
    `item_index` ran to 399 against a maximum of 3; `lookup_queries` were
    measured at 64 characters where 128 is legal. It measured a response the
    model could not legally emit;
  * it never validated a single generated response;
  * it computed the singleton ceiling as **2987**, by formatting 2986.67 with
    `%.0f`, which rounds up. `512 + ceil(1.2 * 2987) = 4097` — one token over.
    Every "safe" length derived from it was derived against a ceiling that does
    not exist;
  * it called `sha256(tokenizer.json)` a *tokenizer manifest*. A manifest covers
    the tokenizer, the chat template, the serving engine, the schema, the prompt
    and the contract, canonically serialised and hashed together;
  * it returned success whenever the synthetic q99 fitted, even when its own
    schema-maximum probe failed.

**A character cap cannot bound token cost**, which the repaired script
demonstrates rather than asserts: at 194 characters per field, Han and Hangul
fit while Cyrillic, Devanagari, Arabic, rare Kana, combining marks and emoji do
not — ZWJ emoji by more than 5x. Tokens per character varies by an order of
magnitude across scripts, so the bound belongs where tokens are known, at the
gateway, and no `maxLength` here can stand in for it.

## Limits are read, never copied

Every number comes from the compiled contract and the schema at run time. The
first version copied them into constants, which is how a report keeps reporting
against limits that have since moved.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import pathlib
import statistics
import sys

REPOSITORY = pathlib.Path(__file__).resolve().parent.parent
CONTRACT = REPOSITORY / "semantic" / "contracts" / "compiled_semantic_contract_v1.json"
FIXTURE_ID = "kpop_cjk_output_stress_v1"

#: Scripts the fixture must cover. The first version tested Latin, Han and
#: Hangul — which are Qwen's best-covered scripts — and concluded from three
#: happy cases that a character cap was safe.
SCRIPTS = {
    "latin": "Midnight",
    "han": "青花瓷",
    "hangul": "사랑의",
    "kana_common": "こころ",
    "kana_rare": "ゔゕゖ",
    "cyrillic": "первый",
    "arabic": "شمس",
    "devanagari": "प्रेम",
    "thai": "ความรัก",
    "emoji": "🎵🎧",
    "emoji_zwj": "👨‍👩‍👧",
    "combining": "é̈ō̈ā̈",
    "json_hostile": 'quote" back\\slash',
}


def load_limits() -> dict[str, int | float]:
    """Limits from the compiled contract, not from memory."""
    contract = json.loads(CONTRACT.read_text())
    output = contract["output_contract"]
    return {
        # **Read, finally.** This was
        # `int(output["uncalibrated_item_reserve_tokens"]) and 512`, an
        # expression that names a contract key, discards it, and evaluates to a
        # constant — the shape of a derivation with none of the substance. The
        # emitter did not publish `envelope_token_reserve` until `bea4d1e`, so
        # there was nothing to read; the docstring above claimed otherwise.
        "envelope_reserve": int(output["envelope_token_reserve"]),
        "max_output_tokens": int(output["max_output_tokens"]),
        "max_items_wire": int(output["max_items_wire"]),
        "calibrated_max_items": int(output["calibrated_max_items"]),
        "max_mentions_per_item": int(output["max_mentions_per_item"]),
        "uncalibrated_item_reserve": int(output["uncalibrated_item_reserve_tokens"]),
        "headroom": 1.0 + float(output["packing_headroom"]),
        "quantile": float(output["predictor_quantile"]),
    }


def singleton_ceiling(lim: dict) -> int:
    """Largest per-item token count that fits one response, floored.

    `x` such that `envelope + ceil(headroom * x) <= max`. It was an inline loop
    with a literal `512` in it — beside a `lim["envelope_reserve"]` the loop did
    not use — so the reserve could move in the contract and the ceiling would
    not. It is a function so a test can ask it about the boundary, which is the
    one number the first version of this program got wrong: 2986.67 formatted
    with `%.0f` gives 2987, and `512 + ceil(1.2 * 2987) = 4097`.
    """
    ceiling = 0
    while (lim["envelope_reserve"]
           + math.ceil(lim["headroom"] * (ceiling + 1))) <= lim["max_output_tokens"]:
        ceiling += 1
    return ceiling


def schema_limits(schema: dict) -> dict:
    """Only what this schema declares.

    Four of these keys — `lookup_queries`, `evidence_fields`,
    `relation_hypotheses` and the relation's `object_label_hypothesis` — do not
    exist in `mention_extract_v2`, and reading them unconditionally is why this
    program could not be pointed at it. What a schema does not carry is not a
    limit with a default; it is a field the response must not contain.
    """
    defs = schema["$defs"]
    # The schema's conditionals became anyOf variants (xgrammar cannot compile
    # if/then, and its matcher leaks on patterned strings — 2026-08-19). The
    # extracted item and the text mention carry every limit this program
    # measures; the tag variant differs only in source_field/index, which are
    # not limits. The old single-def names stay readable so the program can
    # still be pointed at a v1-era schema.
    item = (defs.get("item_extracted") or defs["item"])["properties"]
    mention = (defs.get("mention_text") or defs["mention"])["properties"]
    limits = {
        "schema_version": schema["properties"]["schema_version"]["const"],
        "surface_max": mention["surface"]["maxLength"],
        "canonical_max": mention["canonical_label_hypothesis"]["maxLength"],
        # v3's two label fields, read from the schema like everything else
        # here. They are required, so a response without them is invalid and a
        # budget measured without them is short by two strings per mention.
        **({"english_max": mention["english_label"]["maxLength"]}
           if "english_label" in mention else {}),
        **({"original_max": mention["original_label"]["maxLength"]}
           if "original_label" in mention else {}),
        "source_field_enum": mention["source_field"]["enum"],
        "family_enum": mention["family_hypothesis"]["enum"],
        "role_enum": mention["mention_role"]["enum"],
        "item_index_max": item["item_index"]["maximum"],
        "item_uses_status": "status" in item,
    }
    if "lookup_queries" in mention:
        limits["lookup_max"] = mention["lookup_queries"]["items"]["maxLength"]
        limits["lookup_items"] = mention["lookup_queries"]["maxItems"]
    if "evidence_fields" in mention:
        limits["evidence_enum"] = mention["evidence_fields"]["items"]["enum"]
        limits["evidence_items"] = mention["evidence_fields"]["maxItems"]
    if "relation_hypotheses" in mention:
        limits["relations_max"] = mention["relation_hypotheses"]["maxItems"]
        limits["object_label_max"] = (
            schema["$defs"]["relation_hypothesis"]["properties"]
            ["object_label_hypothesis"]["maxLength"])
    return limits


def make_mention(text: str, lim: dict, unique_salt: int) -> dict:
    """One schema-valid mention at the largest legal size for `text`.

    `lookup_queries` carries `uniqueItems`, so each is salted — the first
    version could emit three identical queries and produce an invalid response
    it then measured.
    """
    surface = text[: lim["surface_max"]]
    mention = {
        "surface": surface,
        "source_field": lim["source_field_enum"][0],
        "source_field_index": None,
        "start": 0,
        "end": max(1, len(surface)),
        "canonical_label_hypothesis": text[: lim["canonical_max"]],
        # From the schema's own enums rather than from memory: `work` and
        # `work_or_franchise` were literals here and `music_recording` leaving
        # the family enum is the kind of move that makes a literal wrong.
        "family_hypothesis": "work" if "work" in lim["family_enum"] else lim["family_enum"][0],
        "mention_role": ("work_or_franchise" if "work_or_franchise" in lim["role_enum"]
                         else lim["role_enum"][0]),
        "conversation_worthy": True,
    }
    # **Present only where the schema declares them.** `additionalProperties` is
    # false, so emitting a key v2 dropped produces an invalid response — which is
    # the failure this program exists to catch rather than commit.
    if "evidence_enum" in lim:
        mention["evidence_fields"] = lim["evidence_enum"][: lim["evidence_items"]]
    if "lookup_items" in lim:
        mention["lookup_queries"] = [
            (f"{unique_salt}-{i}-" + text)[: lim["lookup_max"]]
            for i in range(lim["lookup_items"])
        ]
    # Worst case is the label present and full, never null: the point of this
    # program is what the model *may* emit, not what it usually does.
    if "english_max" in lim:
        mention["english_label"] = text[: lim["english_max"]]
    if "original_max" in lim:
        mention["original_label"] = text[: lim["original_max"]]
    if "relations_max" in lim:
        mention["relation_hypotheses"] = [
            {"predicate": "performed_by",
             "object_label_hypothesis": text[: lim["object_label_max"]]},
            {"predicate": "soundtrack_of",
             "object_label_hypothesis": text[: lim["object_label_max"]]},
        ][: lim["relations_max"]]
    return mention


def make_response(texts: list[str], lim: dict, mentions: int) -> dict:
    """A full, schema-valid response envelope — `item_index` within bounds."""
    def item(index: int, text: str) -> dict:
        body = {
            "item_index": index,
            "mentions": [make_mention(text, lim, m) for m in range(mentions)],
            "abstain_reason": None,
        }
        # v2 replaced the `abstain` boolean with an explicit `status`, and the
        # schema is asked which it wants rather than this file remembering.
        if lim["item_uses_status"]:
            body["status"] = "extracted"
        else:
            body["abstain"] = False
        return body

    return {
        # The schema's own const, so a response cannot claim a version the
        # schema does not answer to.
        "schema_version": lim["schema_version"],
        "items": [item(index, text) for index, text in enumerate(texts)],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tokenizer", required=True)
    parser.add_argument("--model-revision", required=True,
                        help="the revision the tokenizer was downloaded at")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    from tokenizers import Tokenizer
    import jsonschema

    # **The contract names the schema.** This was a hard-coded v1 path beside a
    # contract that had already moved, so the report measured one artifact and
    # was read as describing another.
    contract = json.loads(CONTRACT.read_text())
    schema_path = (REPOSITORY / "semantic" / "contracts" /
                   contract["versions"]["output_schema"].rsplit("/", 1)[-1])
    schema = json.loads(schema_path.read_text())
    lim = load_limits() | schema_limits(schema)
    validator = jsonschema.Draft202012Validator(schema)

    tokenizer_path = pathlib.Path(args.tokenizer)
    tokenizer = Tokenizer.from_file(str(tokenizer_path))

    # **Not a manifest.** One file's digest, named for what it is.
    tokenizer_json_sha256 = hashlib.sha256(tokenizer_path.read_bytes()).hexdigest()

    ceiling = singleton_ceiling(lim)

    def tokens(payload: dict) -> int:
        return len(tokenizer.encode(
            json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
            add_special_tokens=False).ids)

    # ---- 1. paired, length-matched script penalty -------------------------
    #
    # Same character count in every script, so the comparison is of tokenizer
    # behaviour and not of string length.
    per_script: dict[str, int] = {}
    invalid: list[str] = []
    for name, unit in SCRIPTS.items():
        text = (unit * (lim["surface_max"] // max(1, len(unit)) + 1))[: lim["surface_max"]]
        response = make_response([text], lim, lim["max_mentions_per_item"])
        errors = list(validator.iter_errors(response))
        if errors:
            invalid.append(f"{name}: {errors[0].message[:80]}")
        per_script[name] = tokens(response["items"][0])

    # ---- 2. the floor -----------------------------------------------------
    floor_response = make_response(["a"], lim, lim["max_mentions_per_item"])
    if list(validator.iter_errors(floor_response)):
        invalid.append("floor fixture invalid")
    floor = tokens(floor_response["items"][0])

    fits_alone = {name: n <= ceiling for name, n in per_script.items()}
    worst_script = max(per_script, key=lambda k: per_script[k])

    report = {
        "status": "candidate_exploration_not_a_gate_pass",
        "fixture": FIXTURE_ID,
        "model_revision_claimed": args.model_revision,
        "tokenizer_json_sha256": tokenizer_json_sha256,
        # **What was measured, named in the report rather than inferred from
        # when it was run.** A token count is only interpretable against a
        # schema and a contract, and this file previously recorded neither — so
        # a number could outlive the artifact it described with nothing saying
        # so. These are identities, not an attestation: nothing here proves a
        # gateway loaded any of them.
        "output_schema": schema["$id"].rsplit("/", 1)[-1],
        "mention_schema_sha256": hashlib.sha256(schema_path.read_bytes()).hexdigest(),
        "compiled_contract_sha256": hashlib.sha256(CONTRACT.read_bytes()).hexdigest(),
        "tokenizer_manifest_sha256": None,
        "manifest_note": (
            "a manifest hashes tokenizer, chat template, serving engine, schema, "
            "prompt, grammar and compiled contract together; this is one file"),
        "schema_valid_fixtures": not invalid,
        "schema_violations": invalid,
        "singleton_item_ceiling_tokens": ceiling,
        "scaffolding_floor_tokens": floor,
        "tokens_at_schema_max_by_script": per_script,
        "fits_alone_by_script": fits_alone,
        "worst_script": worst_script,
        "worst_script_tokens": per_script[worst_script],
        "batch_size_unchanged": lim["calibrated_max_items"],
        "character_cap_can_bound_tokens": False,
        "gate_blockers": [
            "no deployed gateway attesting model/tokenizer/contract",
            "no overflow route tested",
            "tokenizer_manifest_sha256 not constructed",
            "no measurement against actual deployed Qwen output",
        ],
    }

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"status           {report['status']}")
        print(f"fixture          {FIXTURE_ID}")
        print(f"schema-valid     {'yes' if not invalid else 'NO: ' + '; '.join(invalid)}")
        print(f"singleton ceiling {ceiling} tokens   scaffolding floor {floor}")
        print()
        for name in sorted(per_script, key=lambda k: -per_script[k]):
            print(f"  {name:13} {per_script[name]:6} tokens at schema max  "
                  f"{'fits' if fits_alone[name] else 'DOES NOT FIT'}")
        print()
        print(f"a character cap cannot bound tokens: worst script "
              f"({worst_script}) is {per_script[worst_script] / max(1, per_script['latin']):.1f}x latin")
        print(f"batch size stays {lim['calibrated_max_items']}")
        print()
        print("gate blockers:")
        for blocker in report["gate_blockers"]:
            print(f"  - {blocker}")

    # **Always non-zero.** The gate is not passed by this program, and an exit
    # code of 0 is exactly how a caller would come to believe otherwise.
    return 2


if __name__ == "__main__":
    sys.exit(main())
