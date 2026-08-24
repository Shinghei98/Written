#!/usr/bin/env python3
"""Ask one narrow question about a name, and nothing else.

**Two attempts failed before this one, and both taught the same thing.**
Prompt v14 stated the native-language rule three ways and carried a worked
example of the exact failing character; the result was statistically identical
(4,832 accepted against 4,844). Qwen2.5-72B-AWQ *regressed* — it lost the
Japanese native the 9B got right, shortened `Kim Chaewon` to `Chae Won`, and
invented "Fairy Tale" for `髮如雪`. Size was not the axis; a newer 9B beats an
older 72B, and 4-bit quantisation damages exactly the low-frequency
multilingual knowledge this needs while leaving schema conformance intact.

What is left is **task shape**. In extraction the model answers this question
while also assigning a family, selecting a cardinal root, echoing a parent id,
emitting relations and hitting exact character offsets — in one forward pass,
with thinking disabled and a large grammar constraining every token. Here it
is asked one thing, with two fields to fill and room to think first.

This is a repair pass over a corpus, not part of the extraction lane. It runs
on the same Qwen3.5-9B, reads a JSONL of terms, and writes a JSONL of answers
that `ris_relabel_merge` folds back — never overwriting a label with a worse
one.
"""
from __future__ import annotations

import json
import os
import pathlib
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

#: Deliberately tiny. The extraction schema constrains eighteen fields per
#: mention; this constrains two, so the grammar costs almost nothing and the
#: model spends its budget on the answer rather than on shape.
ANSWER_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["entity_language", "english_label", "original_label"],
    "properties": {
        # **Asked first, and it is the guard rather than a label.** The first
        # pass rendered Los Angeles, Marvel, Spider-Man and 5 Seconds of
        # Summer in katakana — it applied "use the entity's own language" and
        # reached for Japanese as a default. Naming the language *before*
        # writing the name makes the answer checkable: a thing whose language
        # is English may not come back in kana, and the merge refuses it
        # without anyone judging by eye. Han characters cannot separate
        # 路飛 from 漫威电影; a stated language can.
        "entity_language": {"type": "string", "enum": [
            "japanese", "korean", "chinese", "english", "other"]},
        "english_label": {"type": "string", "minLength": 1, "maxLength": 200},
        "original_label": {"type": "string", "minLength": 1, "maxLength": 200},
    },
}

SYSTEM = (
    "You identify what a name is in English and in the language the thing "
    "itself belongs to.\n"
    "Rules:\n"
    "- english_label is the fullest name commonly used in English. Monkey D. "
    "Luffy, not Luffy. Kim Chaewon, not Chaewon.\n"
    "- original_label is the name in the language THE ENTITY belongs to, not "
    "the script this particular text happened to use. A Japanese character or "
    "work written with Chinese characters takes its Japanese name: 路飛 is "
    "モンキー・D・ルフィ, 路人超能100 is モブサイコ100.\n"
    "- When the entity's own language IS the script shown, repeat it "
    "unchanged: 日曆 is Chinese, so its original_label is 日曆.\n"
    "- Never invent. If you do not know the entity, return the given name "
    "unchanged in both fields.\n"
    "- entity_language is where the thing itself is from, NOT the language of "
    "the text you were shown. Los Angeles, Marvel, Spider-Man and 5 Seconds "
    "of Summer are english however they were written. Japanese is only for "
    "things that are actually Japanese."
)


def prompt_for(term: dict, tokenizer) -> str:
    context = term.get("context_title") or ""
    # **The surface too, where it differs from the label.** For `路飛` the
    # extraction already resolved the label to `Luffy`, so a prompt carrying
    # only the label withholds the very characters that say which language
    # the entity belongs to.
    surface = (term.get("surface") or "").strip()
    label = term["label"]
    user = (f"name: {label}\n"
            + (f"also written: {surface}\n"
               if surface and surface != label else "")
            + f"kind: {term.get('family', 'unknown')}\n"
            + (f"seen in: {context}\n" if context else "")
            + "Give english_label and original_label.")
    messages = [{"role": "system", "content": SYSTEM},
                {"role": "user", "content": user}]
    kwargs = {"tokenize": False, "add_generation_prompt": True}
    try:
        # **Thinking on.** It was disabled for extraction because a shared
        # endpoint had to answer many items inside one poll; a repair pass
        # over a corpus has no such constraint, and this is the step that
        # actually needs deliberation.
        return tokenizer.apply_chat_template(messages, enable_thinking=True,
                                             **kwargs)
    except TypeError:
        return tokenizer.apply_chat_template(messages, **kwargs)


def main() -> int:
    terms_path = pathlib.Path(sys.argv[1])
    out_path = pathlib.Path(sys.argv[2])
    terms = [json.loads(line) for line in
             terms_path.read_text().splitlines() if line.strip()]
    print(json.dumps({"stage": "loaded", "terms": len(terms)}), flush=True)

    os.environ.setdefault(
        "MODEL_PATH",
        "/storage2/fs1/erichuang/Active/Users/David/written/models/qwen3.5-9b")
    import serve

    started = time.monotonic()
    engine = serve.engine()
    print(json.dumps({"stage": "engine_ready",
                      "seconds": round(time.monotonic() - started, 1)}),
          flush=True)

    tokenizer = engine.get_tokenizer()
    prompts = [prompt_for(term, tokenizer) for term in terms]
    params = serve._structured_params(ANSWER_SCHEMA, 512)

    started = time.monotonic()
    completions = engine.generate(prompts, params)
    elapsed = round(time.monotonic() - started, 1)
    print(json.dumps({"stage": "generated", "seconds": elapsed,
                      "terms_per_second": round(len(prompts) / max(elapsed, 1), 2)}),
          flush=True)

    with out_path.open("w") as out:
        for term, completion in zip(terms, completions):
            output = completion.outputs[0]
            out.write(json.dumps({
                "key": term["key"], "family": term.get("family"),
                "label": term["label"],
                "finish_reason": output.finish_reason,
                "body": output.text,
            }, ensure_ascii=False) + "\n")
    print(json.dumps({"stage": "done", "written": len(terms),
                      "out": str(out_path)}), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
