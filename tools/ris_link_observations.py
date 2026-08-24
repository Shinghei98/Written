#!/usr/bin/env python3
"""Pair each extracted row with the observation it came from, without the key.

**The join column cannot be computed here, so this joins on content instead.**
`observations.source_item_hmac` is a keyed HMAC of the source item's id, and
the key lives in KMS — it is keyed rather than hashed because source ids are
guessable, so an unkeyed digest would let anyone with read access test whether
a given person liked a given video. RIS has no KMS, so that column is
unusable, and this rebuilds the pairing from what both sides state in the
clear:

    music      title + performer + album, within (user, source, data_type)
    youtube    channel_id + published_at, both stated on each side
    calendar   start time, within (user, source)

**Every strategy refuses ambiguity rather than picking.** Where a key matches
more than one observation the row contributes nothing and is counted as
`ambiguous`; where it matches none it is counted as `unmatched`. A pairing
that guessed would attach one person's term to the wrong evidence, which is
worse than a term with no evidence at all — and the counts are what make the
difference visible instead of a coverage number that looks complete.

**There is an exact route, and it needs one AWS call rather than a key
export.** `aws/ingestion/lib.mjs:160` composes the column as
`HMAC(subkey, "written:item:v1\n<user>\n<source>\n<provider item id>")`, and
`index.mjs`'s `lineageKey()` derives that subkey with **one** KMS `GenerateMac`
over a fixed label — deterministic, cached per invocation, precisely so a
library does not cost 2,540 round trips. So whoever can make that single call
can compute every `source_item_hmac` locally from `distilled_records.item_id`,
which is the provider item id, and join exactly instead of by content.

That would pair all 4,743 observations rather than the 4,085 content matching
reaches, and would fix the two residues content matching cannot: a Spotify row
whose title and performer are shared with another row, and the 298 ambiguous
calendar events that differ only in a field the projection strips. **It is not
done here because RIS has no AWS credentials**, not because the route is
unknown — and it is written down so the next person does not re-derive the
matching heuristics when the cheaper answer is one API call.

    python3 tools/ris_link_observations.py out/ris/links.json [--report]
"""
from __future__ import annotations

import collections
import datetime
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import unicodedata

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]

#: The same map `ris_build_items.py` uses, so a row that was sent for
#: extraction is the row looked up here.
SENT_SOURCES = ("youtube", "apple_music", "music_library", "spotify",
                "apple_calendar", "google_calendar", "outlook_calendar",
                "podcast")

MUSIC = {"apple_music", "music_library", "spotify"}
CALENDAR = {"apple_calendar", "google_calendar", "outlook_calendar"}


def query(sql: str) -> list[dict]:
    """Run a read through the linked project and return its rows.

    **The format is asked for, not assumed, and that cost a run.** `text` is
    the CLI's default; it answered JSON anyway whenever stdout was not a
    terminal, so every call here worked until one was made from a real shell
    and came back as an ASCII table. `--output-format json` makes the answer
    the same wherever it is run.

    **And the answer is found by decoding, not by slicing.** The CLI prefixes
    its output with whatever warnings it has — the Docker "Mounts denied" one
    carries braces of its own — and the payload is an object without the flag
    and a bare array with it. So every `[` or `{` is offered to a real decoder
    and the first that yields rows wins.
    """
    result = subprocess.run(
        ["supabase", "db", "query", "--linked", "--output-format", "json", sql],
        capture_output=True, text=True, cwd=REPOSITORY)
    if result.returncode != 0:
        raise SystemExit(f"query failed: {result.stderr[:400]}")
    decoder = json.JSONDecoder()
    text = result.stdout
    for index, character in enumerate(text):
        if character not in "[{":
            continue
        try:
            value, _ = decoder.raw_decode(text[index:])
        except ValueError:
            continue
        # **Two shapes, because the flag changes it.** Without
        # `--output-format json` the CLI wraps the rows in an object beside a
        # `warning` key; with it the answer is the bare array. Accepting both
        # means this keeps working whichever the CLI decides to send.
        if isinstance(value, list):
            return value
        if isinstance(value, dict) and isinstance(value.get("rows"), list):
            return value["rows"]
    raise SystemExit(f"no json in the answer: {text[:400]}")


def norm(text) -> str:
    """One normalisation, applied where values enter — never per comparison.

    The project has paid for a normalisation applied at three call sites out
    of four; this is the only one, and both sides of every match go through
    it.
    """
    value = unicodedata.normalize("NFKC", str(text or "")).casefold().strip()
    return re.sub(r"\s+", " ", value)


def ts(value) -> str:
    """One instant, one spelling, whichever side stated it.

    Postgres renders `2019-01-31 15:33:59+00` and the distilled row carries
    `2021-09-08T20:00:38Z` — the same instant written two ways, and slicing
    either to nineteen characters compares a space against a `T`. Both go
    through here and come out as `YYYY-MM-DDTHH:MM:SS` in UTC, which is the
    same rule as normalising a label where it enters rather than at each
    comparison.
    """
    text = str(value or "").strip()
    if not text:
        return ""
    text = text.replace(" ", "T")
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    if re.search(r"[+-]\d{2}$", text):       # `+00` -> `+00:00`
        text += ":00"
    try:
        moment = datetime.datetime.fromisoformat(text)
    except ValueError:
        return text[:19]
    if moment.tzinfo is not None:
        moment = moment.astimezone(datetime.timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%S")


#: The tags a title carries, as the projection stores them: the `#` dropped,
#: and word characters only so `#tag,` and `#tag` are one tag.
HASHTAG = re.compile(r"#(\w+)", re.UNICODE)


def hashtags(values) -> tuple:
    """One spelling for a set of tags, whichever side supplied them.

    Order is not meaningful — the projection lists them as the title happened
    to, and a distilled title may differ in case — so both sides are
    normalised and sorted, and the empty set is never a key.
    """
    if not values:
        return ()
    return tuple(sorted({norm(v) for v in values if norm(v)}))


def row_id(row: dict) -> str:
    """Identity as `ris_build_items.py` computes it, so the two agree."""
    return hashlib.sha256("|".join([
        row["user_id"], row["source"], str(row.get("data_type")),
        str(row.get("item_id"))]).encode()).hexdigest()[:40]


def observation_keys(obs: dict) -> list[tuple]:
    """What this observation can be recognised by. May be empty."""
    payload = obs.get("normalized_payload") or {}
    if isinstance(payload, str):
        payload = json.loads(payload)
    source, user, dtype = obs["source_code"], obs["user_id"], obs["data_type"]
    keys = []
    if source in MUSIC:
        # **The ISRC first, because it is an identifier and the rest are
        # descriptions.** It names one recording exactly and permanently, and
        # both sides state it in the clear — the distilled row in `extra`, the
        # observation in its payload. Title-and-performer was reaching for a
        # description when an identifier was sitting there.
        isrc = norm(payload.get("isrc"))
        if isrc:
            keys.append(("isrc", user, source, dtype, isrc))
        title, performer = norm(payload.get("title")), norm(payload.get("primary_performer"))
        if title:
            keys.append(("music", user, source, dtype, title, performer,
                         norm(payload.get("album"))))
            # Album is absent on plenty of rows and present on their distilled
            # twin; a second, weaker key lets those pair while still being
            # refused if it turns out to be ambiguous.
            keys.append(("music_noalbum", user, source, dtype, title, performer))
    elif source == "youtube":
        channel, occurred = payload.get("channel_id"), obs.get("occurred_at")
        if channel and occurred:
            keys.append(("yt", user, dtype, norm(channel), ts(occurred)))
        # **The hashtags are the title, kept** — the projection excludes the
        # title under III.E.4 and keeps the tags lifted out of it, which the
        # distilled row's own title reproduces.
        #
        # **Measured 2026-08-23: this closed nothing**, and the zero is the
        # useful part. Every YouTube row still unmatched has no observation on
        # the other side at all, so the gap there is capture and not matching
        # — no further key can help, and the repair is a backfill like `0313`.
        # Kept because it is correct and costs one lookup, but nobody should
        # expect it to move this corpus.
        tags = hashtags(payload.get("title_hashtags"))
        if tags:
            keys.append(("yt_tags", user, dtype, tags))
        if occurred:
            keys.append(("yt_time", user, dtype, ts(occurred)))
    elif source in CALENDAR:
        if obs.get("occurred_at"):
            keys.append(("cal", user, source, ts(obs["occurred_at"])))
    return keys


def record_keys(row: dict) -> list[tuple]:
    """The same keys, read off the distilled row."""
    extra = row.get("extra") or {}
    if isinstance(extra, str):
        extra = json.loads(extra)
    source, user, dtype = row["source"], row["user_id"], str(row.get("data_type"))
    keys = []
    if source in MUSIC:
        isrc = norm(extra.get("isrc"))
        if isrc:
            keys.append(("isrc", user, source, dtype, isrc))
        title, performer = norm(row.get("name")), norm(row.get("creator"))
        # `detail` is the album only for a library song; the same column
        # carries `playlist=`/`shelf=` elsewhere, and treating those as an
        # album is what put "playlist=周杰伦" into the dictionary.
        detail = str(row.get("detail") or "")
        album = norm(detail) if detail and "=" not in detail.split(" ", 1)[0] else ""
        if title:
            keys.append(("music", user, source, dtype, title, performer, album))
            keys.append(("music_noalbum", user, source, dtype, title, performer))
    elif source == "youtube":
        channel = extra.get("channel_id")
        occurred = (extra.get("published_at") or extra.get("subscribed_at")
                    or extra.get("added_at"))
        if channel and occurred:
            keys.append(("yt", user, dtype, norm(channel), ts(occurred)))
        tags = hashtags(HASHTAG.findall(str(row.get("name") or "")))
        if tags:
            keys.append(("yt_tags", user, dtype, tags))
        if occurred:
            keys.append(("yt_time", user, dtype, ts(occurred)))
    elif source in CALENDAR:
        if extra.get("start"):
            keys.append(("cal", user, source, ts(extra["start"])))
    return keys


def main() -> int:
    out_path = pathlib.Path(sys.argv[1])
    report_only = "--report" in sys.argv

    sources = ", ".join(f"'{s}'" for s in SENT_SOURCES)
    print(json.dumps({"stage": "reading observations"}), flush=True)
    observations = query(f"""
        select id::text, user_id::text, source_code, data_type,
               occurred_at, normalized_payload
          from semantic_private.observations
         where lifecycle_state = 'active'
           and source_code in ({sources})
    """)
    print(json.dumps({"stage": "reading distilled"}), flush=True)
    records = query(f"""
        select user_id::text, source, data_type, item_id, name, creator,
               detail, extra
          from public.summary_distilled_records
         where source in ({sources})
           and coalesce(name,'') <> '' and removed_at is null
           and coalesce(extra ->> 'markedRemoved','') <> '1'
    """)

    # **Built once, from the observation side.** A key claimed by two
    # observations is dropped from the index entirely rather than resolved by
    # order, so it can never pair with anything.
    index: dict[tuple, list[str]] = collections.defaultdict(list)
    for obs in observations:
        for k in observation_keys(obs):
            index[k].append(obs["id"])

    links: dict[str, str] = {}
    unlinked: dict = {"unmatched": [], "ambiguous": []}
    outcome: collections.Counter = collections.Counter()
    per_source: dict = collections.defaultdict(collections.Counter)
    strategy: collections.Counter = collections.Counter()

    for row in records:
        source = row["source"]
        keys = record_keys(row)
        if not keys:
            outcome["no_key"] += 1
            per_source[source]["no_key"] += 1
            continue
        for k in keys:  # strongest first
            found = index.get(k) or []
            if len(found) == 1:
                links[row_id(row)] = found[0]
                outcome["matched"] += 1
                per_source[source]["matched"] += 1
                strategy[k[0]] += 1
                break
            if len(found) > 1:
                continue  # ambiguous on this key; try the next
        else:
            worst = max((len(index.get(k) or []) for k in keys), default=0)
            label = "ambiguous" if worst > 1 else "unmatched"
            outcome[label] += 1
            per_source[source][label] += 1
            # **`unmatched` and `ambiguous` are recorded separately because
            # only one of them is safe to backfill.** An unmatched row has no
            # observation on the other side at all; an ambiguous one has two
            # or more and merely cannot be told which. Re-projecting the
            # second would duplicate evidence that already exists — dedup is
            # by `record_fingerprint`, which a re-projection cannot reproduce.
            unlinked[label].append(row_id(row))

    report = {
        "observations": len(observations),
        "distilled_rows": len(records),
        "outcome": dict(outcome.most_common()),
        "by_strategy": dict(strategy.most_common()),
        "by_source": {s: dict(c.most_common()) for s, c in sorted(per_source.items())},
    }
    report["unlinked"] = unlinked
    print(json.dumps(report, indent=2))
    if not report_only:
        out_path.write_text(json.dumps({**report, "links": links}, indent=1))
        print(json.dumps({"written": str(out_path), "links": len(links)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
