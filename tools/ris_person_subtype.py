#!/usr/bin/env python3
"""Ask what kind of person each person is — one closed answer, or none.

**The owner's rule (2026-08-25), enforced by shape rather than by prose:**
every accepted person maps onto the owner's closed categories — nine since
2026-09-08, a ranked list of up to three with a confidence each, since a
person may hold more than one and the page shows the heaviest — and a person
fitting none is held unminted. The list is a schema-enforced enum, so an
invented category is unemittable, the same move that made an invented
candidate id unemittable in the placement pass.

**Why this exists:** the v19 proposal pass measured what happens when
occupation has nowhere to live — the model proposed "Singers", "Musicians",
"Chinese actors" and eleven more occupation-headings, ~14 of the 39 that
crossed the mint floor. The subtype is the closed slot that information
belongs in; it is a facet beside the parent, never a parent.

This is the narrow-question shape a fourth time (`ris_relabel`,
`ris_parent`, `ris_parent_propose`), because it has moved behaviour every
time prompt text moved nothing.

    python3 tools/ris_person_subtype.py answers_out.jsonl terms.jsonl [more_terms.jsonl ...]
"""
from __future__ import annotations

import json
import os
import pathlib
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

NONE = "none"

#: **The owner's nine, 2026-09-08 — controlled categories of person.** A
#: person may hold more than one; the page shows the one with the most
#: weight. `character` is gone: a fictional character is not a person, the
#: work it belongs to is the term. The answer is a ranked list of up to
#: three, each with a confidence, so the weights are the model's own and
#: the emitter writes support rows rather than one winner. Mirrors the
#: check constraint in migration 0477; if the two disagree the database's
#: governs and the emitter's insert says so loudly.
SUBTYPES = [
    "performer", "composer", "author", "host", "athlete",
    "actor", "director", "streamer", "content_creator",
]
ANSWER_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["categories"],
    "properties": {
        "categories": {
            "type": "array",
            "maxItems": 3,
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": ["category", "confidence"],
                "properties": {
                    "category": {"type": "string", "enum": SUBTYPES},
                    "confidence": {"type": "number", "minimum": 0, "maximum": 1},
                },
            },
        },
    },
}
SYSTEM = (
    "You say what kinds of person a named person is, from this closed list, "
    "most representative first, with a confidence for each. Most people are "
    "one kind; give a second or third only when the person is genuinely "
    "known for it too.\n"
    "- performer: sings, dances or plays music for audiences - singers, "
    "idols, dancers, instrumentalists, conductors, comedians on stage.\n"
    "- composer: writes music, whoever performs it.\n"
    "- author: writes books, audiobooks or blogs.\n"
    "- host: presents a television or radio programme, a podcast or a "
    "ceremony - hosts, anchors, MCs.\n"
    "- athlete: competes in sport.\n"
    "- actor: performs in film, TV or on stage.\n"
    "- director: directs film, TV or stage productions.\n"
    "- streamer: broadcasts live on streaming platforms - Twitch, YouTube "
    "Live, AfreecaTV.\n"
    "- content_creator: a YouTube, TikTok or Instagram channel personality "
    "who is not a streamer.\n"
    "\n"
    "A fictional character - from a film, a series, an animation or a game - "
    "is not a person: answer an empty list. A historical figure known for "
    "nothing on this list, or a visual artist, is also an empty list.\n"
    "\n"
    "An empty list is a correct answer. A stretch is worse than none: an "
    "empty list keeps the person waiting for a better answer, a wrong kind "
    "files them under it."
)


def prompt_for(term: dict, tokenizer) -> str:
    titles = [t for t in (term.get("context_titles") or []) if t]
    related = [r for r in (term.get("related") or []) if r]
    lines = [f"person: {term['label']}"]
    if term.get("seen"):
        lines.append(f"appears in {term['seen']} items")
    if titles:
        lines.append("seen in:")
        lines.extend(f"  - {t}" for t in titles)
    if related:
        lines.append("known about them:")
        lines.extend(f"  - {r}" for r in related)
    user = "\n".join(lines) + "\n\nWhat kind of person is this?"
    messages = [{"role": "system", "content": SYSTEM},
                {"role": "user", "content": user}]
    kwargs = {"tokenize": False, "add_generation_prompt": True}
    try:
        return tokenizer.apply_chat_template(messages, enable_thinking=True,
                                             **kwargs)
    except TypeError:
        return tokenizer.apply_chat_template(messages, **kwargs)


def main() -> int:
    out_path = pathlib.Path(sys.argv[1])
    #: Several term files, because the persons live in two: the placement
    #: build's ask file and the resolved file — a person the catalogue already
    #: parents still needs a kind. Deduped on the pass's own key.
    seen: set = set()
    persons: list[dict] = []
    for arg in sys.argv[2:]:
        for line in pathlib.Path(arg).read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            term = json.loads(line)
            if term.get("family") != "person":
                continue
            if term["key"] in seen:
                continue
            seen.add(term["key"])
            persons.append(term)
    print(json.dumps({"stage": "loaded", "persons": len(persons)}), flush=True)
    if not persons:
        out_path.write_text("", encoding="utf-8")
        return 0

    os.environ.setdefault(
        "MODEL_PATH",
        "/storage2/fs1/erichuang/Active/Users/David/written/models/qwen3.5-9b")
    import serve

    started = time.monotonic()
    engine = serve.engine()
    print(json.dumps({"stage": "engine_ready",
                      "seconds": round(time.monotonic() - started, 1)}), flush=True)

    tokenizer = engine.get_tokenizer()
    prompts = [prompt_for(t, tokenizer) for t in persons]
    params = serve._structured_params(ANSWER_SCHEMA, 512)

    started = time.monotonic()
    completions = engine.generate(prompts, params)
    print(json.dumps({"stage": "generated",
                      "seconds": round(time.monotonic() - started, 1)}), flush=True)

    written = unparseable = 0
    with out_path.open("w", encoding="utf-8") as handle:
        for term, completion in zip(persons, completions):
            text = completion.outputs[0].text if completion.outputs else ""
            try:
                answer = json.loads(text[text.index("{"):text.rindex("}") + 1])
            except (ValueError, json.JSONDecodeError):
                unparseable += 1
                continue
            categories = [c for c in (answer.get("categories") or [])
                          if c.get("category") in SUBTYPES]
            handle.write(json.dumps({
                "key": term["key"],
                "label": term["label"],
                "grounded": bool(term.get("grounded")),
                # ranked, most representative first; empty means none fits
                "categories": categories,
                # the head of the list, for readers of the old shape
                "subtype": categories[0]["category"] if categories else None,
                "confidence": categories[0]["confidence"] if categories else None,
            }, ensure_ascii=False) + "\n")
            written += 1

    print(json.dumps({"stage": "written", "answers": written,
                      "unparseable": unparseable, "out": str(out_path)}),
          flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
