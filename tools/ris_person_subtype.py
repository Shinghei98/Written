#!/usr/bin/env python3
"""Ask what kind of person each person is — one closed answer, or none.

**The owner's rule (2026-08-25), enforced by shape rather than by prose:**
every accepted person maps onto exactly one of twelve closed subtypes, the most
representative where several fit, and a person fitting none is held unminted.
"Exactly one" is not an instruction here — the schema is a single-select enum,
so a second subtype is unemittable, the same move that made an invented
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

#: The owner's twelve, 2026-08-25. **Grammar, not nouns** — a closed role
#: vocabulary like the 18 families, not a term list. Mirrors the check
#: constraint in migration 0342; if the two ever disagree, the database's is
#: the one that governs and the emitter's insert will say so loudly.
SUBTYPES = [
    "actor", "music_performer", "composer", "director",
    "streamer", "content_creator", "athlete", "comedian",
    "character", "author", "artist", "historical_figure",
]

ANSWER_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["subtype", "confidence"],
    "properties": {
        "subtype": {"type": "string", "enum": [*SUBTYPES, NONE]},
        "confidence": {"type": "number", "minimum": 0, "maximum": 1},
    },
}

SYSTEM = (
    "You say what kind of person a named person is. Exactly one kind, from "
    "this list:\n"
    "- actor: performs in film, TV or on stage.\n"
    "- music_performer: sings or plays music for audiences - singers, idols, "
    "instrumentalists, conductors.\n"
    "- composer: writes music, whoever performs it.\n"
    "- director: directs film, TV or stage productions.\n"
    "- streamer: broadcasts live on streaming platforms.\n"
    "- content_creator: makes YouTube, Instagram or TikTok content.\n"
    "- athlete: competes in sport.\n"
    "- comedian: performs comedy.\n"
    "- character: a person from a created work - fiction, animation, games. "
    "Not a real human being.\n"
    "- author: writes books, audiobooks or blogs.\n"
    "- artist: makes visual art - painting, sculpture, photography.\n"
    "- historical_figure: known for their place in history rather than for "
    "any of the above.\n"
    "\n"
    "If several fit, choose the one the person is most known for. A composer "
    "who also performed is whichever they are most known as.\n"
    "\n"
    "If none fits, answer 'none'. A stretch is worse than none: 'none' keeps "
    "the person waiting for a better answer, a wrong kind files them under it."
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
            handle.write(json.dumps({
                "key": term["key"],
                "label": term["label"],
                "grounded": bool(term.get("grounded")),
                "subtype": answer.get("subtype"),
                "confidence": answer.get("confidence"),
            }, ensure_ascii=False) + "\n")
            written += 1

    print(json.dumps({"stage": "written", "answers": written,
                      "unparseable": unparseable, "out": str(out_path)}),
          flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
