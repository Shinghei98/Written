#!/usr/bin/env python3
"""Turn the proposal pass's answers into a migration, and let the gates decide.

**This emitter files evidence; it mints nothing.** Every proposal — grounded or
not — becomes a `semantic_private.parent_proposals` row, because evidence is
never discarded; then the migration calls
`semantic_private.mint_proposed_parents(floor)`, where both gates live:
ungrounded proposers never count, and a heading below the floor of distinct
grounded proposers holds pending rather than minting. Keeping the gates in the
database means a hand-written insert cannot slip past them — the emitter could
be wrong about everything and the worst outcome is a held proposal.

The corpus stamp and the floor are derived and stated, not assumed: the stamp
comes from the compiled contract (`ris_v14` sat hardcoded in the dictionary
emitter across four prompt versions, mislabelling every corpus it wrote), and
the floor is printed into the migration where a reader will see it.

    python3 tools/ris_emit_parent_proposals.py proposals.jsonl <n> [floor]
"""
from __future__ import annotations

import json
import pathlib
import sys

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]
CONTRACT = REPOSITORY / "semantic" / "contracts" / "compiled_semantic_contract_v1.json"


def quote(text) -> str:
    return "'" + str(text).replace("'", "''") + "'"


def normalise(text: str) -> str:
    """The kept minter's own normalisation, restated in Python.

    `lower(regexp_replace(btrim(x), '\\s+', ' ', 'g'))` — one rule, because the
    proposal must collide with an existing concept label exactly where the
    minter's collision check would look for it.
    """
    return " ".join((text or "").strip().lower().split())


def main() -> int:
    proposals = [json.loads(line) for line
                 in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
                 if line.strip()]
    number = sys.argv[2]
    floor = int(sys.argv[3]) if len(sys.argv) > 3 else 3

    contract = json.loads(CONTRACT.read_text(encoding="utf-8"))
    corpus = "ris_" + contract["versions"]["prompt"].rsplit("_", 1)[-1]

    kept, skipped = [], 0
    for proposal in proposals:
        label = (proposal.get("parent_label") or "").strip()
        family = proposal.get("parent_family")
        hub = proposal.get("hub") or ""
        if not label or not family or not hub.startswith("hub:"):
            skipped += 1
            continue
        # **A heading that restates its term is the term wearing a hat.** The
        # proposal prompt forbids it; a model that does it anyway is caught
        # here rather than trusted.
        if normalise(label) == normalise(proposal.get("label")):
            skipped += 1
            continue
        kept.append(proposal)

    grounded = sum(1 for p in kept if p.get("grounded"))
    out = [f"""-- {number} — the corpus's proposed parents, filed for the gates to judge.
--
-- {len(kept)} proposals from the `needs_new_parent` lane of corpus `{corpus}`
-- ({grounded} from grounded terms, {len(kept) - grounded} from inference-only
-- terms — the second kind is filed and never counted). {skipped} were refused
-- at emission: no label, no hub, or a heading that merely restated its term.
--
-- **This migration decides nothing.** `mint_proposed_parents({floor})` holds
-- both gates — only grounded proposers count, and a heading needs {floor}
-- distinct ones to mint. Whatever falls short stays pending, so the next
-- corpus's proposals accumulate onto these rather than starting over.

insert into semantic_private.parent_proposals
  (normalized_label, proposal_label, family, hub_key,
   proposed_by_term, grounded, confidence, corpus)
values"""]
    rows = []
    for p in sorted(kept, key=lambda x: (normalise(x["parent_label"]),
                                         x["parent_family"], x["key"])):
        conf = p.get("confidence")
        rows.append("  ({}, {}, {}, {}, {}, {}, {}, {})".format(
            quote(normalise(p["parent_label"])),
            quote(p["parent_label"][:120]),
            quote(p["parent_family"]),
            quote(p["hub"]),
            quote(p["key"]),
            "true" if p.get("grounded") else "false",
            "null" if conf is None else round(float(conf), 4),
            quote(corpus)))
    out.append(",\n".join(rows))
    out.append("""on conflict (normalized_label, family, proposed_by_term, corpus)
  do nothing;
""")
    out.append(f"""do $$
declare
  receipt jsonb;
begin
  receipt := semantic_private.mint_proposed_parents({floor});
  raise notice '{number}: %', receipt;
end;
$$;
""")

    path = (REPOSITORY / "supabase" / "migrations"
            / f"{number}_the_corpus_proposes_its_missing_parents.sql")
    path.write_text("\n".join(out) + "\n", encoding="utf-8")
    print(json.dumps({"proposals": len(kept), "grounded": grounded,
                      "skipped": skipped, "floor": floor, "corpus": corpus,
                      "migration": str(path)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
