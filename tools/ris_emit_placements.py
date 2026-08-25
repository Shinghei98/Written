#!/usr/bin/env python3
"""Emit the per-hub placements — one row per (term, hub), and the primary.

**The owner's rule (2026-08-25) reaching the database.** The assembly's
per-hub union goes to `semantic_private.presumed_term_placements` (0353),
whose unique constraint is the "never twice within a hub" half; the primary
column keeps its exact prior semantics and is updated the way `0351`/`0352`
updated it. Holdout keys are stripped — experiment artifacts never overwrite
production. A bare hub never appears here: the assembler refuses hub-level
answers as placements, because routing judged as assignment turned 24
abstentions into fake misassignments in one measured evaluation run.

Upsert semantics on the hub-unique key: a later corpus's answer for an
occupied hub updates the row — a deeper answer to the same question — and
never adds a second.

    python3 tools/ris_emit_placements.py out/ris/v19_placements.jsonl \\
        out/ris/holdout_truth.json <n>
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
    placements_path = pathlib.Path(sys.argv[1])
    holdout = set(json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")))
    number = sys.argv[3]
    corpus = "ris_" + json.loads(CONTRACT.read_text())["versions"]["prompt"].rsplit("_", 1)[-1]

    primaries, placements = [], []
    multi = 0
    for line in placements_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        if row["key"] in holdout:
            continue
        label = normalise(row.get("label"))
        family = row.get("family")
        if not label or not family:
            continue
        primary = row.get("primary")
        if primary and not primary.startswith("hub:") \
                and primary not in ("none", "needs_new_parent"):
            primaries.append((label, family, primary,
                              float(row.get("primary_confidence") or 0)))
        kept = [p for p in row.get("placements") or ()]
        if len(kept) > 1:
            multi += 1
        for p in kept:
            source = ("inherited" if p["stage"] == "inherited"
                      else "placement_pass")
            placements.append((label, family, p["parent"], p["hub"],
                               float(p.get("confidence") or 0), source))

    # **One row per constrained key, decided here rather than by the batch.**
    # Two raw keys can normalise to one (label, family) — the join defect this
    # chain has met before — and `on conflict do update` refuses to touch a
    # row twice in one statement, so an in-batch duplicate is a failed apply.
    # Highest confidence wins; ties break on the parent key so a replay writes
    # the same rows.
    best = {}
    for l, f, parent, h, c, src in placements:
        held = best.get((l, f, h))
        if held is None or (c, parent) > (held[4], held[2]):
            best[(l, f, h)] = (l, f, parent, h, c, src)
    placements = list(best.values())

    out = [f"""-- {number} — per-hub placements land: one per hub, many across hubs.
--
-- The owner's rule of 2026-08-25, populated from the four-stage cascade
-- ({corpus}): rung-2, anchor inheritance, within-hub re-place, and the
-- cross-hub second ask that runs wherever a term's anchor lives in a hub the
-- term held no placement in. {len(placements)} placements across
-- {multi}-term multi-hub cases; {len(primaries)} primary updates with the
-- same lane-guarded semantics as 0351/0352. Measured before emission:
-- holdout misassignment 3.0% under any-placement scoring, anchor
-- incongruence 2.2%.

do $$
declare
  n integer;
  missing text;
begin
  create temporary table _primary
    (normalized_label text, family text, parent_key text, confidence numeric)
    on commit drop;
  insert into _primary values"""]
    out.append(",\n".join(
        "    ({}, {}, {}, {})".format(quote(l), quote(f), quote(p), round(c, 4))
        for l, f, p, c in sorted(primaries)))
    out.append(f"""  ;
  select string_agg(distinct p.parent_key, ', ') into missing
    from _primary p
   where not exists (select 1 from ontology.concepts c
                      where c.concept_key = p.parent_key
                        and c.retired_at is null);
  if missing is not null then
    raise notice '{number}: primary headings not held here, skipped: %', missing;
  end if;

  update semantic_private.presumed_terms t
     set proposed_parent_concept_id = c.id,
         proposed_parent_confidence_unvalidated = p.confidence,
         proposed_parent_source = 'placement_pass'
    from _primary p
    join ontology.concepts c
      on c.concept_key = p.parent_key and c.retired_at is null
   where t.normalized_label = p.normalized_label
     and t.family = p.family
     and coalesce(t.proposed_parent_source, 'placement_pass') = 'placement_pass';
  get diagnostics n = row_count;
  raise notice '{number}: % primary placements landed', n;

  create temporary table _placement
    (normalized_label text, family text, parent_key text, hub_key text,
     confidence numeric, source text)
    on commit drop;
  insert into _placement values""")
    out.append(",\n".join(
        "    ({}, {}, {}, {}, {}, {})".format(
            quote(l), quote(f), quote(p), quote(h), round(c, 4), quote(s))
        for l, f, p, h, c, s in sorted(placements)))
    out.append(f"""  ;
  insert into semantic_private.presumed_term_placements
    (normalized_label, family, parent_concept_id, hub_key,
     confidence, source, corpus)
  select p.normalized_label, p.family, c.id, p.hub_key,
         p.confidence, p.source, {quote(corpus)}
    from _placement p
    join ontology.concepts c
      on c.concept_key = p.parent_key and c.retired_at is null
  on conflict (normalized_label, family, hub_key) do update
    set parent_concept_id = excluded.parent_concept_id,
        confidence = excluded.confidence,
        source = excluded.source,
        corpus = excluded.corpus;
  get diagnostics n = row_count;
  raise notice '{number}: % per-hub placements landed', n;
  if n = 0 then
    raise exception
      '{number}: placements were emitted and none matched a concept';
  end if;
end;
$$;
""")

    path = (REPOSITORY / "supabase" / "migrations"
            / f"{number}_placements_one_per_hub.sql")
    path.write_text("\n".join(out) + "\n", encoding="utf-8")
    print(json.dumps({"primaries": len(primaries),
                      "placements": len(placements),
                      "multi_hub_terms": multi, "corpus": corpus,
                      "migration": str(path)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
