#!/usr/bin/env python3
"""Ask what the missing parent should be — cheaply enough to actually get asked.

**The create-new arm of the ladder, which until now did not exist in practice.**
The extraction schema's `missing_parent_proposal` requires seven authored
fields — label, definition, cardinal root, broader parent, example children,
non-examples, rationale — which is authoring a taxonomy entry inline, in one
forward pass, beside seventeen other fields. **Zero proposals were produced in
1,540 items, across every prompt version this project has run.** An escape
hatch that has never once opened is not an escape hatch, and its absence is why
491 of 1,262 placements dumped into broad buckets instead: the model had no way
to say "the right heading is missing".

This is the `ris_relabel` shape a third time — one question, thinking on,
enum-constrained where an enum exists — because that shape has now moved
behaviour twice where prompt text moved nothing (native labels: 1,459 repaired;
placement: 9.3% -> 98.8%).

Four fields, three of them closed:

* `parent_label` — open, as the grammar's open-noun rule requires. The one
  thing genuinely being authored.
* `parent_family` — the wire's 18 families, an enum.
* `hub` — the grandparent, an enum of the 15 published hubs **read from the
  candidates file**, never listed here: a hardcoded copy is a second file that
  can disagree with the first, this session's thrice-paid defect. The hub is
  never invented, so a minted parent always lands under a real top-level home.
* `confidence`.

The aggregation and the N-floor live downstream (`ris_parent_mint_build.py`):
this pass proposes, it does not decide. `culture:taiwan` is the acceptance
case — family `culture`, hub `places_cultures`, and `family_mint_convention`
already knows that family's key prefix and default parent.

    python3 tools/ris_parent_propose.py answers.jsonl parents.jsonl \\
            candidates.json proposals.jsonl
"""
from __future__ import annotations

import json
import os
import pathlib
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

NEEDS_NEW = "needs_new_parent"

#: The wire's family enum, restated from `mention_extract_v5.schema.json`. A
#: proposal in a family off the wire could never have been extracted, so the
#: enum closes the door the schema already closes one stage earlier.
FAMILIES = ["person", "group", "organization", "franchise", "work", "anime",
            "book", "game", "music_work", "album", "sport", "activity", "art",
            "field", "place", "culture", "event", "tour"]


def answer_schema(hubs: list[str]) -> dict:
    return {
        "type": "object",
        "additionalProperties": False,
        "required": ["parent_label", "parent_family", "hub", "confidence"],
        "properties": {
            "parent_label": {"type": "string", "minLength": 2, "maxLength": 120},
            "parent_family": {"type": "string", "enum": FAMILIES},
            "hub": {"type": "string", "enum": hubs},
            "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        },
    }


SYSTEM = (
    "A term needs a heading, and no existing heading fits. You name the "
    "heading that should exist.\n"
    "\n"
    "You are given the term, what kind of thing it is, the titles it was seen "
    "in, anything known about it, and the list of top-level areas.\n"
    "\n"
    "Name the missing heading:\n"
    "- parent_label: the heading's name, as a reader would recognise it — a "
    "genre, a franchise, a country's culture, a field of study. Never restate "
    "the term itself; the heading must be broader than the term.\n"
    "- parent_family: what kind of thing the heading is.\n"
    "- hub: the one top-level area the heading itself belongs under.\n"
    "\n"
    "Name headings that many other terms would also belong under. A heading "
    "with one conceivable member is the term wearing a hat."
)


def prompt_for(term: dict, hubs: list[dict], tokenizer) -> str:
    listing = "\n".join(f"  {h['term_id']} = {h['label']}" for h in hubs)
    titles = [t for t in (term.get("context_titles") or []) if t]
    related = [r for r in (term.get("related") or []) if r]
    lines = [f"term: {term['label']}", f"kind: {term.get('family', 'unknown')}"]
    if term.get("seen"):
        lines.append(f"appears in {term['seen']} items")
    if titles:
        lines.append("seen in:")
        lines.extend(f"  - {t}" for t in titles)
    if related:
        lines.append("known about it:")
        lines.extend(f"  - {r}" for r in related)
    user = ("\n".join(lines)
            + f"\n\ntop-level areas:\n{listing}\n"
            + "\nWhat heading should exist for this term?")
    messages = [{"role": "system", "content": SYSTEM},
                {"role": "user", "content": user}]
    kwargs = {"tokenize": False, "add_generation_prompt": True}
    try:
        # Thinking on, for the reason the relabel and placement passes turn it
        # on: naming a heading is the deliberation step, not a shape to fill.
        return tokenizer.apply_chat_template(messages, enable_thinking=True,
                                             **kwargs)
    except TypeError:
        return tokenizer.apply_chat_template(messages, **kwargs)


def main() -> int:
    answers = [json.loads(line) for line
               in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
               if line.strip()]
    terms = {json.loads(line)["key"]: json.loads(line) for line
             in pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()
             if line.strip()}
    candidates = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
    out_path = pathlib.Path(sys.argv[4])

    #: The hubs come off the candidate list — since the list now reserves all
    #: fifteen, the enum is complete without a second copy existing anywhere.
    hubs = [c for c in candidates if str(c["term_id"]).startswith("hub:")]
    if not hubs:
        raise SystemExit("no hubs in the candidates file; the enum would be "
                         "empty and every proposal unconstrained")
    hub_ids = [str(h["term_id"]) for h in hubs]

    # **A bare-hub placement is the routing signal, said implicitly.** The
    # explicit exit fired zero times in its first 2,135 live answers while 94%
    # of placements dumped onto hubs — the fifth time this session an
    # instruction lost to the structure of a choice. A term whose best heading
    # after the inheritance merge is still a bare hub is exactly a term whose
    # right parent is missing from the list or from the catalogue, which is
    # what `needs_new_parent` was defined to mean; the model just says it by
    # choosing the vaguest defensible thing. So both spellings route here, and
    # the gates downstream stay the decision-makers either way — a proposal
    # for a term genuinely at home under its hub simply never gathers three
    # grounded proposers for anything finer.
    def routed(answer: dict) -> bool:
        if answer.get("parent_source") == "catalogue":
            return False
        parent = answer.get("parent") or ""
        return parent == NEEDS_NEW or parent.startswith("hub:")

    asked = [terms[a["key"]] for a in answers
             if routed(a) and a["key"] in terms]
    print(json.dumps({"stage": "loaded", "needs_new_parent": len(asked),
                      "hubs": len(hub_ids)}), flush=True)
    if not asked:
        out_path.write_text("", encoding="utf-8")
        print(json.dumps({"stage": "written", "proposals": 0,
                          "out": str(out_path)}), flush=True)
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
    prompts = [prompt_for(t, hubs, tokenizer) for t in asked]
    params = serve._structured_params(answer_schema(hub_ids), 512)

    started = time.monotonic()
    completions = engine.generate(prompts, params)
    elapsed = round(time.monotonic() - started, 1)
    print(json.dumps({"stage": "generated", "seconds": elapsed}), flush=True)

    written = unparseable = 0
    with out_path.open("w", encoding="utf-8") as handle:
        for term, completion in zip(asked, completions):
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
                # **Travels with the proposal, because the guard reads it
                # downstream**: a term attested only by inference may propose
                # nothing that counts.
                "grounded": bool(term.get("grounded")),
                "parent_label": answer.get("parent_label"),
                "parent_family": answer.get("parent_family"),
                "hub": answer.get("hub"),
                "confidence": answer.get("confidence"),
            }, ensure_ascii=False) + "\n")
            written += 1

    print(json.dumps({"stage": "written", "proposals": written,
                      "unparseable": unparseable, "out": str(out_path)}),
          flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
