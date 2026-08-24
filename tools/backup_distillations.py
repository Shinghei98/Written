#!/usr/bin/env python3
"""Back up every distillation, and separate what may be trained on from what may not.

**Losing a distillation is losing a person's afternoon.** That sentence is the
whole reason this exists: the collaborators gave their data on a standing
agreement that nobody re-distils for us, and the only thing making that true is
that we still hold what they gave.

    python3 tools/backup_distillations.py            # out/backup/<date>/
    python3 tools/backup_distillations.py --out DIR

**Two files, not one, and the split is the point.** `distillations.jsonl` is
everything, for restoring; `training_corpus.jsonl` is the subset a model may see.
A single file plus a remembered filter is exactly how a corpus quietly acquires
rows nobody consented to — so the filter runs here, once, and the difference is
visible as two line counts.

## What the corpus filter is, and why it is not a preference

The query is written at the foot of `0041` and is reproduced here in code:

    join private.collaborators  — consent, recorded out of band, per person
    and source not in ('youtube', 'spotify')

**Neither exclusion is ours to waive.** Spotify IV.2.1.a forbids ingesting its
content into a model and IV.2.5 says a user's consent does not cure that;
YouTube's III.E.4.h and the Content Categorization amendment say the same from
the other side. The rights were never the collaborator's to give.

## What this cannot back up

**`raw_source_records.encrypted_payload` is excluded.** 22,361 rows of
ciphertext under per-user data keys only KMS can unwrap — without the AWS lane
it is bytes nobody can read, so copying it would produce a large file with no
recoverable content and the false comfort of a number. Its *metadata* is kept,
because that is what says a row existed.

**And the raw archive is forward-only.** `RawArchive` keeps what each source
replied from the moment it shipped; every distillation taken before that has no
raw copy and never will — those responses were parsed and dropped. This backup
is therefore the most complete thing that exists for the historical data, and
`distilled_records` is the floor beneath which nothing can be recovered.
"""
from __future__ import annotations

import argparse
import datetime
import json
import pathlib
import sys

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPOSITORY / "tools"))

from ris_build_items import query  # noqa: E402

#: Excluded from any training set by the platforms' own terms, whatever anybody
#: consented to. Named here as well as at the foot of `0041` because a rule that
#: lives only in a comment is a rule somebody will re-derive differently.
MODEL_INELIGIBLE_SOURCES = ("youtube", "spotify")


def dump(path: pathlib.Path, rows: list[dict]) -> int:
    """One JSON object per line, UTF-8 with no BOM.

    JSONL rather than CSV because `extra` is itself structured and a CSV of it
    would need the escaping this project already keeps getting right in one
    place — and because a partial write leaves a readable prefix rather than a
    corrupt table.
    """
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, default=str) + "\n")
    return len(rows)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=pathlib.Path, default=None)
    arguments = parser.parse_args()

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M")
    out = arguments.out or (REPOSITORY / "out" / "backup" / stamp)
    out.mkdir(parents=True, exist_ok=True)

    manifest: dict = {"taken_at": stamp, "files": {}, "notes": {}}

    # ---------------------------------------------------------------- everything
    #
    # **Every row, every account, every source.** This is the restore copy and
    # the one that must not be filtered: a backup that quietly dropped the
    # sources a corpus may not use would be a backup you cannot restore from.
    records = query("""
        select user_id, source, data_type, item_id, name, creator, detail,
               extra, collected_at, distilled_at, removed_at, removed_reason
          from public.distilled_records
         order by user_id, source, data_type, item_id, distilled_at
    """)
    manifest["files"]["distillations.jsonl"] = dump(
        out / "distillations.jsonl", records
    )

    # ---------------------------------------------------------------- the corpus
    #
    # The query at the foot of `0041`, run rather than quoted.
    corpus = query(f"""
        select d.user_id, d.source, d.data_type, d.item_id, d.name, d.creator,
               d.detail, d.extra, d.collected_at, d.distilled_at
          from public.distilled_records d
          join private.collaborators c on c.user_id = d.user_id
         where d.source not in {MODEL_INELIGIBLE_SOURCES!r}
           -- **A struck-off row is kept and never counted.** `BanList` marks
           -- rather than deletes, precisely so the website's *never used, never
           -- shown, never counted* is true — and a training set is the loudest
           -- form of "counted". 20 rows carry `removed_at` today. They stay in
           -- the restore copy, because striking off is a reading decision the
           -- person can reverse, and a backup that dropped them would make it
           -- irreversible.
           and d.removed_at is null
         order by d.user_id, d.source, d.data_type, d.item_id
    """)
    manifest["files"]["training_corpus.jsonl"] = dump(
        out / "training_corpus.jsonl", corpus
    )

    # ------------------------------------------------------------- the dictionary
    #
    # Not personal data in the same sense — the terms are global — but it is the
    # thing every measurement in `docs/PROJECT-CONTEXT.md` was taken against,
    # and a number quoted from a dictionary nobody kept is unverifiable.
    manifest["files"]["presumed_terms.jsonl"] = dump(
        out / "presumed_terms.jsonl",
        query("""select id, normalized_label, family, canonical_label,
                        english_label, original_label, origin, source_lanes,
                        canonical_term_id, excluded_reason, first_seen_at
                   from semantic_private.presumed_terms order by normalized_label, family"""))
    manifest["files"]["presumed_term_relations.jsonl"] = dump(
        out / "presumed_term_relations.jsonl",
        query("""select subject_term_id, predicate, object_term_id, basis,
                        observed_count from semantic_private.presumed_term_relations
                  order by subject_term_id, predicate, object_term_id"""))

    # ------------------------------------------------------------- vault metadata
    #
    # The ciphertext is deliberately absent; see the module docstring. What is
    # kept is the shape — which rows existed, under which run, of which type —
    # because that is what makes a later "did we have this" answerable.
    manifest["files"]["vault_metadata.jsonl"] = dump(
        out / "vault_metadata.jsonl",
        query("""select id, user_id, ingestion_run_id, source_code, data_type,
                        occurred_at, record_fingerprint, encryption_key_version,
                        lifecycle_state, retained_until, created_at,
                        octet_length(encrypted_payload) as ciphertext_bytes
                   from semantic_private.raw_source_records
                  order by created_at"""))

    manifest["notes"] = {
        "corpus_filter": (
            "join private.collaborators, and source not in "
            f"{list(MODEL_INELIGIBLE_SOURCES)} — the query at the foot of 0041. "
            "Neither exclusion is waivable by consent: Spotify IV.2.1.a/IV.2.5 "
            "and YouTube III.E.4.h bind whoever holds the API keys."
        ),
        "vault_ciphertext": (
            "encrypted_payload is not copied. It is unwrappable only through "
            "KMS, so a copy without the AWS lane is unreadable bytes."
        ),
        "raw_archive": (
            "RawArchive keeps each source's own reply from the build it shipped "
            "in. Distillations taken before that have no raw copy and never "
            "will, so distilled_records is the floor for historical data."
        ),
    }

    (out / "MANIFEST.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    print(json.dumps({
        "out": str(out),
        **manifest["files"],
        # **Both numbers, side by side.** The gap between them is how many rows
        # exist that no model may see, and seeing it is the point of the split.
        "held_but_not_trainable":
            manifest["files"]["distillations.jsonl"]
            - manifest["files"]["training_corpus.jsonl"],
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
