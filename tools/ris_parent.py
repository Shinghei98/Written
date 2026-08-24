#!/usr/bin/env python3
"""Ask one question about where a term belongs, and nothing else.

**The extraction answers this while doing eighteen other things.**
`parent_candidate_id` sits beside a family, a cardinal root, a user predicate,
relation hypotheses, ranked alternatives and exact character offsets, in one
forward pass with thinking disabled and a large grammar constraining every
token. Measured on David's v17 run: **374 of 4,003 mentions parented, 9.3%, and
zero proposals** — with Chopin taking `Classical` and Bach taking nothing off
the same list in the same run. That is not disagreement about Bach; it is a
field that did not get attended to.

`ris_relabel` established the shape and the evidence: v14 stated the
native-language rule three ways and carried a worked example, and the result was
statistically identical (4,832 against 4,844). One narrow question with two
fields and room to think repaired 1,459 labels. This is that, for placement.

**The candidate id is an enum, not a string.** The extraction schema takes a
free string and the validator refuses it afterwards if it was not one of the
supplied ids — a check that has to run and can be failed. Here the grammar makes
an invented id *unemittable*, which is the same move the closed family and role
vocabularies already make. `"none"` is an explicit member for the same reason it
is elsewhere: a null inside an enum is not a shape this stack trusts xgrammar
with.

    python3 tools/ris_parent.py parents.jsonl candidates.json answers.jsonl
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

#: **Two fields.** The confidence is not decoration: the merge refuses a low
#: one rather than trusting every answer equally, and a pass whose answers are
#: all uncertain should be visible as that rather than as placement.
def answer_schema(ids: list[str]) -> dict:
    return {
        "type": "object",
        "additionalProperties": False,
        "required": ["parent", "confidence"],
        "properties": {
            "parent": {"type": "string", "enum": [*ids, NONE]},
            "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        },
    }


#: **What the tree actually looks like, read off it rather than asserted.**
#: Published `broader` edges, 2026-08-24: creator->genre 2,441; creator->era
#: 665; work->hub 305; subject->hub 293; creator->subject 267; activity->hub
#: 146; work->genre 79. So a person or group under a genre is the ordinary
#: case, not a category error — which is worth saying, because it reads like
#: one.
SYSTEM = (
    "You place a term under the one heading it best belongs to.\n"
    "\n"
    "You are given a term, what kind of thing it is, the title it was seen in, "
    "and a list of headings. Choose the heading it belongs under, or 'none'.\n"
    "\n"
    "How this catalogue is organised:\n"
    "- a person or a group belongs under the genre or tradition they work in "
    "(a composer under Classical, an idol group under K-Pop)\n"
    "- a work, album or song belongs under its genre, or under the broad area "
    "it is part of\n"
    "- an activity or subject belongs under the broad area it is part of\n"
    "\n"
    "Choose 'none' only when no heading is defensible. A heading that is "
    "broader than the term is still correct — that is what a heading is. "
    "Do not choose a heading merely because the words overlap.\n"
    "\n"
    "Answer with the heading's id and how confident you are."
)


def prompt_for(term: dict, candidates: list[dict], tokenizer) -> str:
    listing = "\n".join(f"  {c['term_id']} = {c['label']}" for c in candidates)
    context = (term.get("context_title") or "").strip()
    user = (f"term: {term['label']}\n"
            + f"kind: {term.get('family', 'unknown')}\n"
            + (f"seen in: {context}\n" if context else "")
            + f"\nheadings:\n{listing}\n"
            + "\nWhich heading does this term belong under?")
    messages = [{"role": "system", "content": SYSTEM},
                {"role": "user", "content": user}]
    kwargs = {"tokenize": False, "add_generation_prompt": True}
    try:
        # Thinking on, for the reason the relabel pass turns it on: a repair
        # pass over a corpus is not a shared endpoint answering many items in
        # one poll, and this is the step that needs deliberation.
        return tokenizer.apply_chat_template(messages, enable_thinking=True,
                                             **kwargs)
    except TypeError:
        return tokenizer.apply_chat_template(messages, **kwargs)


def main() -> int:
    terms = [json.loads(line) for line
             in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
             if line.strip()]
    candidates = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
    out_path = pathlib.Path(sys.argv[3])
    ids = [str(c["term_id"]) for c in candidates]
    print(json.dumps({"stage": "loaded", "terms": len(terms),
                      "candidates": len(ids)}), flush=True)

    os.environ.setdefault(
        "MODEL_PATH",
        "/storage2/fs1/erichuang/Active/Users/David/written/models/qwen3.5-9b")
    import serve

    started = time.monotonic()
    engine = serve.engine()
    print(json.dumps({"stage": "engine_ready",
                      "seconds": round(time.monotonic() - started, 1)}), flush=True)

    tokenizer = engine.get_tokenizer()
    prompts = [prompt_for(t, candidates, tokenizer) for t in terms]
    params = serve._structured_params(answer_schema(ids), 512)

    started = time.monotonic()
    completions = engine.generate(prompts, params)
    elapsed = round(time.monotonic() - started, 1)
    print(json.dumps({"stage": "generated", "seconds": elapsed,
                      "terms_per_second": round(len(prompts) / max(elapsed, 1), 2)}),
          flush=True)

    written = unparseable = 0
    with out_path.open("w", encoding="utf-8") as handle:
        for term, completion in zip(terms, completions):
            text = completion.outputs[0].text if completion.outputs else ""
            try:
                answer = json.loads(text[text.index("{"):text.rindex("}") + 1])
            except (ValueError, json.JSONDecodeError):
                unparseable += 1
                continue
            handle.write(json.dumps({
                "key": term["key"],
                "label": term["label"],
                "family": term.get("family"),
                "parent": answer.get("parent"),
                "confidence": answer.get("confidence"),
            }, ensure_ascii=False) + "\n")
            written += 1

    print(json.dumps({"stage": "written", "answers": written,
                      "unparseable": unparseable, "out": str(out_path)}), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
