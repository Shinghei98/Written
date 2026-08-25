#!/usr/bin/env python3
"""Fold the within-hub re-place answers back into the dictionary's proposals.

**What this updates and what it refuses to.** The re-place run takes terms the
placement pass left on bare hubs and asks again over the full authored
inventory, so its specific answers *overwrite* the hub-level proposals `0344`
wrote — a deeper answer to the same question, from the same lane. It never
touches a proposal that did not come from the placement lane
(`proposed_parent_source <> 'placement_pass'` is left alone), and `none` /
`needs_new_parent` write nothing: the first is an honest refusal, the second
is the proposal lane's routing answer.

Keys are re-normalised through the dictionary's own `normalise`, because the
build's key is NFKC+casefold and the dictionary's adds whitespace collapse and
release-suffix stripping — the join defect measured and fixed once already
(`load_parents`' header), honoured here rather than re-learned.

**Every heading resolves best-effort with the misses counted**, the
inherited-heading rule from `0344`: the per-hub inventories are read off the
live tree, which includes runtime-minted concepts a clean replay does not
hold, so a raise would make the load unreplayable over headings production
genuinely has.

    python3 tools/ris_emit_replacements.py out/ris/replace <n>
"""
from __future__ import annotations

import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from ris_emit_dictionary import normalise, quote  # noqa: E402

REPOSITORY = HERE.parent
CONTRACT = REPOSITORY / "semantic" / "contracts" / "compiled_semantic_contract_v1.json"


def main() -> int:
    directory = pathlib.Path(sys.argv[1])
    number = sys.argv[2]
    corpus = "ris_" + json.loads(CONTRACT.read_text())["versions"]["prompt"].rsplit("_", 1)[-1]

    rows, none_ct, routed = [], 0, 0
    for path in sorted(directory.glob("replace_*.jsonl")):
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            answer = json.loads(line)
            parent = answer.get("parent")
            if parent == "none":
                none_ct += 1
                continue
            if parent == "needs_new_parent":
                routed += 1
                continue
            key = normalise(answer.get("label"))
            if not key or not answer.get("family"):
                continue
            rows.append((key, answer["family"], parent,
                         float(answer.get("confidence") or 0)))

    out = [f"""-- {number} — the re-placed headings overwrite their hub-level proposals.
--
-- The within-hub re-place ({corpus}): the placement pass's bare-hub answers
-- asked again over the full authored inventory — the one `0346`/`0348`/`0349`
-- built — and {len(rows)} terms took a specific heading. {none_ct} refused
-- (`none`, honest), {routed} routed to the proposal lane. A specific answer
-- to the same question from the same lane overwrites the hub proposal it
-- replaces; proposals from any other source are untouched.
--
-- Headings resolve best-effort with misses counted (`0344`'s inherited rule):
-- the inventories were read off the live tree, which holds runtime-minted
-- concepts a clean replay does not.

do $$
declare
  n integer;
  missing text;
begin
  create temporary table _replacement
    (normalized_label text, family text, parent_key text, confidence numeric)
    on commit drop;
  insert into _replacement values"""]
    out.append(",\n".join(
        "    ({}, {}, {}, {})".format(quote(k), quote(f), quote(p), round(c, 4))
        for k, f, p, c in sorted(rows)))
    out.append(f"""  ;
  select string_agg(distinct r.parent_key, ', ') into missing
    from _replacement r
   where not exists (select 1 from ontology.concepts c
                      where c.concept_key = r.parent_key
                        and c.retired_at is null);
  if missing is not null then
    raise notice '{number}: headings not held here, skipped: %', missing;
  end if;

  update semantic_private.presumed_terms t
     set proposed_parent_concept_id = c.id,
         proposed_parent_confidence_unvalidated = r.confidence,
         proposed_parent_source = 'placement_pass'
    from _replacement r
    join ontology.concepts c
      on c.concept_key = r.parent_key and c.retired_at is null
   where t.normalized_label = r.normalized_label
     and t.family = r.family
     and coalesce(t.proposed_parent_source, 'placement_pass') = 'placement_pass';
  get diagnostics n = row_count;
  raise notice '{number}: % of % re-placements landed', n,
    (select count(*) from _replacement);
  if n = 0 then
    raise exception
      '{number}: re-placements were emitted and none matched a term';
  end if;
end;
$$;
""")

    path = (REPOSITORY / "supabase" / "migrations"
            / f"{number}_the_replaced_headings_land.sql")
    path.write_text("\n".join(out) + "\n", encoding="utf-8")
    print(json.dumps({"replacements": len(rows), "none": none_ct,
                      "routed_to_proposals": routed, "corpus": corpus,
                      "migration": str(path)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
