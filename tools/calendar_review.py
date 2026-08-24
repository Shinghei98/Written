#!/usr/bin/env python3
"""Assemble §8's fourth Phase 2 gate: the Calendar promotions, for a person to read.

    export SUPABASE_SECRET_KEY=sb_secret_...
    python3 tools/calendar_review.py <user_id> [--sample 4]

Writes `calendar-review-<user>.md` and prints **counts only**. The file holds
event titles, so it is git-ignored beside `written-distillation-*.csv` and
`ontology-terms.csv`, and it is not something to paste anywhere.

## Why this reconstructs the decision instead of reading it back

**The vault cannot tell you which event a promotion was about, and that is the
privacy property rather than a gap.** `observations.normalized_payload` is at
most four keys — schema version, record kind, `classification_state`,
`artifact_type` — because the classifier's own contract is that the private
title *"participates only in the HMAC lineage and is not returned"*. The one
key that could identify the row, `source_item_hmac`, is salted per user with a
KMS key that only the classifier's IAM role may use.

So §10's *"review every Calendar promotion"* cannot be performed from the vault
alone, by design. The honest route is to re-derive the same decision from the
same input: `public.distilled_records` holds the legacy calendar rows in exactly
the shape `CalendarClassifier.classify` reads, and this builds the classifier the
way `aws/classifier/handler.py` builds it — same package, same four offline
catalogs. Nothing is decrypted and no KMS call is made.

**The reproduction is checked rather than assumed.** The script compares its own
counts against `semantic_private.observations` for that user and says so. If
they disagree, this is classifying with a different configuration from the
Lambda and its output is describing a classifier nobody deployed — which is the
one way this review could quietly be worthless.

## What "stratified" means here

§8 asks for *"a stratified sample of abstentions"*, not a sample of rows: the
strata are the classifier's own dispositions, so a disposition that fired twice
is represented alongside one that fired seventy times. Sampling rows uniformly
would show `excluded_unknown` seventy times and never show the interesting ones.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import sys
import urllib.error
import urllib.request

BASE = "https://fwnezkbesjoazlpaflbq.supabase.co"


def env_key() -> str:
    key = os.environ.get("SUPABASE_SECRET_KEY", "").strip()
    if not key:
        sys.exit(
            "SUPABASE_SECRET_KEY is not set.\n\n"
            "It bypasses row level security entirely, so it lives in your shell "
            "for the length of this run and nowhere else."
        )
    return key


def get(path: str, key: str):
    req = urllib.request.Request(f"{BASE}{path}")
    req.add_header("apikey", key)
    req.add_header("Authorization", f"Bearer {key}")
    try:
        with urllib.request.urlopen(req) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        sys.exit(f"GET {path} failed: {error.code}\n{error.read().decode()}")


def _require_modern_python() -> None:
    """`written_ontology` needs 3.11, and `python3` here is Xcode's 3.9.

    **The failure is six frames deep and names `enum`**, not this tool and not
    the interpreter — `ImportError: cannot import name 'StrEnum'` from a path
    inside `Xcode.app`, which reads as the package being broken. It is the same
    trap `tools/export_terms_to_label.py` already carries a note about, and
    carrying the note in one tool did not help anybody running the other.

    So this refuses early and names a working interpreter it has actually found,
    rather than telling somebody to install something they already have.
    """
    if sys.version_info >= (3, 11):
        return

    candidates = [
        pathlib.Path(directory) / name
        for directory in ("/opt/homebrew/bin", "/usr/local/bin")
        for name in ("python3.14", "python3.13", "python3.12", "python3.11")
    ]
    found = next((c for c in candidates if c.exists()), None)
    here = " ".join([pathlib.Path(sys.argv[0]).name, *sys.argv[1:]])
    sys.exit(
        f"this needs Python 3.11 or newer and is running {sys.version.split()[0]}"
        f" from {sys.executable}.\n\n"
        + (f"Run it with:\n\n    {found} tools/{here}\n"
           if found else
           "No newer interpreter was found in /opt/homebrew/bin or "
           "/usr/local/bin.\n")
    )


def _ensure_written_ontology() -> None:
    """Find the package in the repository when it is not installed.

    `written_ontology` lives at `semantic/src/` and is installed only into a
    virtual environment somebody remembered to make. A tool that exists to be
    run once, by hand, at the moment somebody finally sits down to a review
    gate, cannot also be a tool that requires `pip install -e semantic` first —
    the failure is a bare `ModuleNotFoundError` three frames deep, which reads
    as the tool being broken.

    The path is added rather than the package vendored, for the same reason the
    Lambdas vendor rather than reimplement: there must be exactly one copy of
    the classifier, and this must be reading the copy the tests cover.
    """
    try:
        import written_ontology  # noqa: F401
        return
    except ModuleNotFoundError:
        pass

    source = pathlib.Path(__file__).resolve().parent.parent / "semantic" / "src"
    if not (source / "written_ontology").is_dir():
        sys.exit(
            f"written_ontology is not installed and is not at {source}.\n"
            "Install it with `pip install -e semantic` from the repository root."
        )
    sys.path.insert(0, str(source))


def classifier_for(user_id: str):
    """Built exactly as `aws/classifier/handler.py:classifier_for` builds it.

    The four offline catalogs are what decide whether a booking is a recognised
    vendor, so constructing without one would silently reclassify. The lineage
    signer is the one thing that differs: the Lambda derives an HMAC key from
    KMS and this has no such key and needs none — the hash identifies a row to
    the database, and here the row is already in front of us.
    """
    _ensure_written_ontology()
    from written_ontology.calendar_semantics import CalendarClassifier
    from written_ontology.export_adapter import (
        _OFFLINE_CALENDAR_CARRIERS,
        _OFFLINE_CALENDAR_PLACE_CATALOG,
        _OFFLINE_CALENDAR_PLACE_LABELS,
        _OFFLINE_LEISURE_VENDORS,
    )

    return CalendarClassifier(
        place_catalog=_OFFLINE_CALENDAR_PLACE_CATALOG,
        place_labels=_OFFLINE_CALENDAR_PLACE_LABELS,
        carrier_codes=_OFFLINE_CALENDAR_CARRIERS,
        recognized_leisure_vendors=_OFFLINE_LEISURE_VENDORS,
        # **A constant is not a signer.** The Lambda derives an HMAC key from
        # KMS and this has none and needs none — the hash identifies a row to
        # the database and the row is already in front of us. What it must
        # still do is *distinguish*: `build_journeys` and
        # `derive_travel_candidates` key journeys by this value, so a constant
        # collapses every journey somebody ever took into one. It was returning
        # `"review-only"` for all of them, which read as a person with a single
        # trip. A plain digest of the content keeps the property that matters
        # and claims no secrecy it does not have.
        lineage_signer=lambda content: hashlib.sha256(
            content if isinstance(content, bytes) else str(content).encode("utf-8")
        ).hexdigest(),
    )


def rows_for(user_id: str, key: str) -> list[dict]:
    """Calendar events as the classifier reads them, one row per event.

    **Through `summary_distilled_records`, never the table**, which is this
    project's own standing rule and which the first version of this tool broke.
    `distilled_records` is append-only across every run, so a re-distilled
    calendar is in there several times: David's 106 events were 158 rows, and
    the review reported **9 promotions where the vault holds 5** — eight flight
    segments for four flights, each counted once per distillation.

    Demo matched at 9 and 9 on the same broken code, because its four duplicate
    rows happened not to be promotable ones. So the agreement check did not fail
    on the account that would have exonerated it and passed on the other; only
    running both caught it.

    `source` is normalised to `apple_calendar` and `data_type` to `event`, which
    is what the Lambda does — it hardcodes both, so a Google Calendar row goes
    through the identical path there and must here.
    """
    collected: list[dict] = []
    for source in ("apple_calendar", "google_calendar"):
        found = get(
            f"/rest/v1/summary_distilled_records?user_id=eq.{user_id}"
            f"&source=eq.{source}&data_type=eq.event"
            "&select=item_id,name,creator,detail,extra,collected_at", key,
        ) or []
        for row in found:
            collected.append({
                "source": "apple_calendar",
                "data_type": "event",
                "item_id": row.get("item_id") or "",
                "name": row.get("name") or "",
                "detail": row.get("detail") or "",
                "creator": row.get("creator") or "",
                "extra": row.get("extra") or "",
                "_origin": source,
            })
    return collected


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("user_id")
    parser.add_argument("--sample", type=int, default=4,
                        help="abstentions to show per disposition (default 4)")
    args = parser.parse_args()

    # Before the key is read, so a wrong interpreter is not diagnosed as a
    # missing credential — and before the network, so it costs nothing.
    _require_modern_python()

    key = env_key()
    rows = rows_for(args.user_id, key)
    if not rows:
        sys.exit("no calendar events for that user")

    classifier = classifier_for(args.user_id)

    included: list[tuple[dict, object]] = []
    excluded: dict[str, list[tuple[dict, object]]] = {}
    dispositions: dict[str, int] = {}

    for row in rows:
        decision = classifier.classify(row, calendar_metadata=None)
        name = str(decision.disposition)
        dispositions[name] = dispositions.get(name, 0) + 1
        if decision.included:
            included.append((row, decision))
        else:
            excluded.setdefault(name, []).append((row, decision))

    lines: list[str] = []
    out = lines.append
    out(f"# Calendar review — {args.user_id}\n")
    out(f"{len(rows)} events, {len(included)} promoted, "
        f"{len(rows) - len(included)} abstained.\n")
    out("Reproduced from `public.distilled_records` with the same classifier and "
        "the same four offline catalogs the Lambda uses. Nothing was decrypted.\n")

    out("\n## Dispositions\n")
    for name, count in sorted(dispositions.items(), key=lambda kv: -kv[1]):
        out(f"- `{name}` — {count}")

    out("\n## Every promotion\n")
    out("**Read each of these.** §10 allows one verified ticket to create only "
        "its typed booked/scheduled predicate, so a wrong promotion here is a "
        "claim about somebody's life made from a misread calendar entry.\n")
    for row, decision in included:
        activity = getattr(decision, "booked_activity", None)
        flight = getattr(decision, "flight_segment", None)
        starts = getattr(flight, "starts_at", None) or getattr(activity, "starts_at", None)
        vendor = getattr(activity, "vendor_key", None)
        out(f"\n### {row['name'] or '(untitled)'}")
        out(f"- disposition: `{decision.disposition}`")
        out(f"- source: {row['_origin']}")
        if starts:
            out(f"- starts: {starts}")
        if row["detail"]:
            out(f"- location: {row['detail']}")
        if vendor:
            out(f"- vendor: `{vendor}`")
        if row["creator"]:
            out(f"- organizer: {row['creator']}")
        out(f"- extra: `{row['extra']}`")
        out("- **verdict:** _(right / wrong / unsure — write here)_")

    out("\n## Stratified sample of abstentions\n")
    out("One group per disposition, so a rule that fired twice is as visible as "
        "one that fired seventy times. Looking for the opposite mistake: an "
        "event that *should* have been promoted and was not.\n")
    for name, items in sorted(excluded.items(), key=lambda kv: -len(kv[1])):
        out(f"\n### `{name}` — {len(items)} total, showing "
            f"{min(args.sample, len(items))}")
        # First-N rather than random: the run has to be reproducible, and a
        # review somebody half-finishes should show the same rows next time.
        for row, _ in items[:args.sample]:
            detail = f" — {row['detail']}" if row["detail"] else ""
            out(f"- {row['name'] or '(untitled)'}{detail}")
        out("- **verdict:** _(any of these wrongly excluded? write here)_")

    path = pathlib.Path(f"calendar-review-{args.user_id[:8]}.md")
    path.write_text("\n".join(lines), encoding="utf-8")

    print(f"{len(rows)} events -> {len(included)} promoted, "
          f"{len(rows) - len(included)} abstained")
    print("dispositions: " + ", ".join(
        f"{n}={c}" for n, c in sorted(dispositions.items(), key=lambda kv: -kv[1])))

    # **Per source, because the totals are not comparable.** A source the vault
    # never captured has no counterpart there — Google Calendar reached the
    # vault for the first time on 2026-08-12 and only for one account — so a
    # single total invites the reader to call a legitimate difference a
    # mismatch, or worse to wave one through.
    by_source: dict[str, int] = {}
    for row, _ in included:
        by_source[row["_origin"]] = by_source.get(row["_origin"], 0) + 1
    print("promoted by source: " + (", ".join(
        f"{s}={n}" for s, n in sorted(by_source.items())) or "none"))

    print(f"\nwrote {path} — it holds event titles, so it is git-ignored")
    print("Compare each source above against that source's `candidate` count in "
          "`semantic_private.observations`. A source absent from the vault is "
          "expected to differ; a source present and disagreeing means this "
          "reproduced a different classifier.")


if __name__ == "__main__":
    main()
