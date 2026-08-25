#!/usr/bin/env python3
"""Turn the subtype pass's answers into a migration, counted out loud.

`none` is never written: null **is** the held-pending state (0342), and a
stored `none` would be indistinguishable from a person the pass never reached
— the same rule the placement answers follow. The subtype list is restated in
0342's check constraint; an answer off the list dies there loudly rather than
being filtered here silently, so the two copies cannot drift without a failed
apply saying so.

    python3 tools/ris_emit_person_subtypes.py answers.jsonl <n>
"""
from __future__ import annotations

import collections
import json
import pathlib
import sys

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]
CONTRACT = REPOSITORY / "semantic" / "contracts" / "compiled_semantic_contract_v1.json"


def quote(text) -> str:
    return "'" + str(text).replace("'", "''") + "'"


def main() -> int:
    answers = [json.loads(line) for line
               in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
               if line.strip()]
    number = sys.argv[2]
    corpus = "ris_" + json.loads(CONTRACT.read_text())["versions"]["prompt"].rsplit("_", 1)[-1]

    counts: collections.Counter = collections.Counter()
    rows = []
    for answer in answers:
        subtype = answer.get("subtype")
        counts[subtype or "none"] += 1
        if not subtype or subtype == "none":
            continue
        key = answer["key"].rsplit("|", 1)[0]
        rows.append((key, subtype))

    held = counts["none"]
    out = [f"""-- {number} — the corpus's persons take their kinds ({corpus}).
--
-- {len(rows)} persons assigned one of the owner's twelve closed subtypes;
-- {held} answered `none` and stay null — held unminted, not refused, per
-- 0342. Distribution: {dict(counts.most_common())}.
--
-- Updates key on (normalized_label, family='person'); a person this corpus
-- named that the dictionary does not hold updates nothing, and the count
-- below says how many landed rather than leaving the difference silent.

do $$
declare
  n integer := 0;
  touched integer;
begin"""]
    for key, subtype in sorted(rows):
        out.append(
            "  update semantic_private.presumed_terms\n"
            f"     set person_subtype = {quote(subtype)},\n"
            "         person_subtype_source = 'model_pass'\n"
            f"   where normalized_label = {quote(key)} and family = 'person'\n"
            "     and person_subtype is null;\n"
            "  get diagnostics touched = row_count; n := n + touched;")
    out.append(f"""  raise notice '{number}: % of {len(rows)} subtype assignments landed', n;
  if {len(rows)} > 0 and n = 0 then
    raise exception
      '{number}: assignments were emitted and none matched a dictionary row';
  end if;
end;
$$;
""")

    path = (REPOSITORY / "supabase" / "migrations"
            / f"{number}_the_persons_take_their_kinds.sql")
    path.write_text("\n".join(out) + "\n", encoding="utf-8")
    print(json.dumps({"assigned": len(rows), "held_none": held,
                      "distribution": dict(counts.most_common()),
                      "corpus": corpus, "migration": str(path)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
