#!/usr/bin/env python3
"""Fold the relabel pass back into the verdicts, refusing every worse answer.

**A repair pass may improve a label and may never damage one.** The extraction
answers are the floor: this replaces one only where the new answer is
demonstrably better by a stated test, and the tests are deliberately blunt
because a subtle one cannot be checked by reading the report.

    replace the native  when the current native merely echoes the surface
                        and the new native differs from it
    replace the English when the new one *contains* the old as a word-prefix
                        (Luffy -> Monkey D. Luffy) — never when it is merely
                        different, which is how `Kim Chaewon` became
                        `Chae Won` on the 72B probe

Anything else is counted and discarded. The counts are the point: a pass that
improved nothing must report zero rather than looking like it ran.

**A guard was built here, tested, and removed on the evidence.** The first pass
rendered Los Angeles, Marvel, Spider-Man and 5 Seconds of Summer in katakana —
34 kana natives, roughly two-thirds of them wrong. The intended fix was to make
the model name the entity's language first and refuse any native whose script
contradicted it. It does not work, because the model answers `english` for One
Piece, Promare and Re:Zero — the English name being the one it knows best —
so the guard would have refused every repair the pass exists for while
catching nothing.

What actually fixed it was the prompt line naming the failures ("Los Angeles,
Marvel, Spider-Man and 5 Seconds of Summer are english however they were
written"): kana natives fell from 34 to 6, and all six are genuinely Japanese.
The field is still asked for and still reported, because the distribution is
worth seeing, but nothing branches on it. **A guard that would refuse the
cases it was written to protect is worse than no guard**, and the only way to
know which it was, was to run both and compare.
"""
from __future__ import annotations

import collections
import json
import pathlib
import re
import sys
import unicodedata

SUFFIX = (" - single", " - ep", " (single)", " (ep)", " live version",
          " remastered", " single", " ep")

def key(text: str) -> str:
    value = re.sub(r"\s+", " ",
                   unicodedata.normalize("NFKC", (text or "").strip()).casefold())
    changed = True
    while changed:
        changed = False
        for suffix in SUFFIX:
            if value.endswith(suffix) and len(value) > len(suffix):
                value = value[: -len(suffix)].strip()
                changed = True
    return value


def main() -> int:
    verdicts_path = pathlib.Path(sys.argv[1])
    answers_path = pathlib.Path(sys.argv[2])
    out_path = pathlib.Path(sys.argv[3])

    verdicts = json.loads(verdicts_path.read_text())
    counts: collections.Counter = collections.Counter()

    answers: dict = {}
    for line in answers_path.read_text().splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        if row.get("finish_reason") == "length":
            counts["truncated"] += 1
            continue
        try:
            body = json.loads(row["body"])
        except (ValueError, TypeError):
            counts["unparseable"] += 1
            continue
        english = (body.get("english_label") or "").strip()
        native = (body.get("original_label") or "").strip()
        # `entity_language` is read for the report and never acted on — see
        # the note in the module docstring.
        counts["language_" + ((body.get("entity_language") or "?").lower())] += 1
        if english or native:
            answers[row["key"]] = {"english": english, "native": native}
    counts["answers"] = len(answers)

    for verdict in verdicts["verdicts"]:
        for mention in verdict["mentions"]:
            surface = (mention.get("surface") or "").strip()
            label = mention.get("canonical_label_hypothesis") or surface
            answer = answers.get(key(label))
            if not answer:
                continue

            native = (mention.get("original_label") or "").strip()
            # Only where the old native was an echo — a native that already
            # differed from the surface was answered correctly, and this pass
            # has no standing to second-guess it.
            if answer["native"] and (not native or native == surface) \
                    and answer["native"] != surface:
                mention["original_label"] = answer["native"]
                counts["native_replaced"] += 1
            elif answer["native"]:
                counts["native_kept"] += 1

            english = (mention.get("english_label") or "").strip()
            new = answer["english"]
            if new and english and new != english:
                # A widening, not a rewrite. `Luffy` -> `Monkey D. Luffy`
                # passes; `Kim Chaewon` -> `Chae Won` does not.
                widened = (english.casefold() in new.casefold()
                           and len(new) > len(english))
                if widened:
                    mention["english_label"] = new
                    counts["english_widened"] += 1
                else:
                    counts["english_refused"] += 1
            elif new and not english:
                mention["english_label"] = new
                counts["english_filled"] += 1

    verdicts["relabel"] = dict(counts.most_common())
    out_path.write_text(json.dumps(verdicts, ensure_ascii=False, indent=1))
    print(json.dumps(dict(counts.most_common()), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
