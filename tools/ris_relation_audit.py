#!/usr/bin/env python3
"""Ground and corroborate every promoted model-stated relation edge.

**The doctrine (owner, 2026-08-26), from the Black Myth: Wukong finding:**
the model stated "aespa part_of_franchise Black Myth: Wukong" on two
entries that say, in full, "aespa" and a Winter fancam title — the game
appears in neither. Two statements by the same model from the same prior
are one witness speaking twice, so the N>=2 promotion floor was defeated
by a consistent hallucination, and propagation amplified real aespa
listening into a game nobody touched.

The split that fixes it without breaking franchise-first minting
(*identity mints, weight measures*):

- **Grounded** — the object's name appears in at least one source entry
  that stated the relation. The entry is the witness; the edge stands.
- **Ungrounded but corroborated** — the object is model world-knowledge,
  and Wikidata connects the two entities (a claim on either references
  the other). Iron Man -> MCU survives here; the edge stands, stamped.
- **Ungrounded and uncorroborated** — a fabrication wearing a relation's
  clothes. The edge demotes to `candidate`: identity keeps its mint,
  conduction stops, the cutoff does the rest.

Reads the catalogue over WRITTEN_DATABASE_URL, grounds against every
verdicts/results + items file under out/ris (entry text = the item's
field values joined), corroborates the ungrounded remainder against
Wikidata (patient client, 429-backoff), and writes an audit JSON the
demotion migration bakes in.

    WRITTEN_DATABASE_URL=... python3 tools/ris_relation_audit.py \\
        /path/to/out/ris out/relation_audit.json
"""
from __future__ import annotations

import json
import os
import pathlib
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

EDGES = """
select e.id as edge_id, e.predicate_key,
       sc.concept_key as subject_key, oc.concept_key as object_key,
       (select l.label from ontology.concept_labels l
         where l.concept_id = sc.id and l.status = 'active'
         order by (l.label_type = 'preferred') desc, l.ontology_version_id desc
         limit 1) as subject_label,
       (select l.label from ontology.concept_labels l
         where l.concept_id = oc.id and l.status = 'active'
         order by (l.label_type = 'preferred') desc, l.ontology_version_id desc
         limit 1) as object_label
from ontology.concept_edges e
join ontology.versions v on v.id = e.ontology_version_id and v.status = 'published'
join ontology.concepts sc on sc.id = e.subject_concept_id
join ontology.concepts oc on oc.id = e.object_concept_id
where e.status = 'active'
  and e.provenance_type = 'learned'
  and e.predicate_key in ('part_of_franchise', 'member_of_group',
                          'performed_by', 'composed_by')
  and (e.provenance ->> 'source' = '0374_relation_promotion'
       or e.provenance ->> 'source' is null)
"""


def norm(text: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", (text or "")).casefold().split())


def _api(params: dict) -> dict:
    url = ("https://www.wikidata.org/w/api.php?format=json&"
           + urllib.parse.urlencode(params))
    request = urllib.request.Request(url, headers={
        "User-Agent": "written-relation-audit/1.0 (research; contact: owner)"})
    delay = 2.0
    for attempt in range(5):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as error:
            if error.code != 429 or attempt == 4:
                raise
            time.sleep(delay)
            delay *= 2
    raise RuntimeError("unreachable")


def entity_ids(label: str) -> list[str]:
    time.sleep(1.0)
    try:
        found = _api({"action": "wbsearchentities", "language": "en",
                      "type": "item", "limit": 5, "search": label})
    except Exception:  # noqa: BLE001 - absence, not failure
        return []
    return [hit["id"] for hit in found.get("search", [])
            if norm(hit.get("label") or "") == norm(label)
            or norm(hit.get("match", {}).get("text") or "") == norm(label)]


def claims_reference(qids_a: list[str], qids_b: list[str]) -> str | None:
    """A claim on any A referencing any B (or the reverse) corroborates."""
    if not qids_a or not qids_b:
        return None
    time.sleep(1.0)
    try:
        entities = _api({"action": "wbgetentities", "props": "claims",
                         "ids": "|".join((qids_a + qids_b)[:10])})
    except Exception:  # noqa: BLE001
        return None
    set_a, set_b = set(qids_a), set(qids_b)
    for qid, entity in (entities.get("entities") or {}).items():
        other = set_b if qid in set_a else set_a if qid in set_b else set()
        if not other:
            continue
        for claim_list in (entity.get("claims") or {}).values():
            for claim in claim_list:
                value = (claim.get("mainsnak", {}).get("datavalue", {})
                         .get("value") or {})
                if isinstance(value, dict) and value.get("id") in other:
                    return f"{qid}->{value.get('id')}"
    return None


def main() -> int:
    database_url = os.environ.get("WRITTEN_DATABASE_URL")
    if not database_url:
        print("WRITTEN_DATABASE_URL is not set", file=sys.stderr)
        return 2
    corpus_dir = pathlib.Path(sys.argv[1])
    out_path = pathlib.Path(sys.argv[2])

    import psycopg
    from psycopg.rows import dict_row
    with psycopg.connect(database_url, row_factory=dict_row,
                         prepare_threshold=None) as connection:
        with connection.cursor() as cursor:
            cursor.execute(EDGES)
            edges = cursor.fetchall()

    # ------------------------------------------------------------------
    # Entry texts per (subject, predicate, object), from every corpus
    # verdicts file beside its items file.
    # ------------------------------------------------------------------
    items_text: dict[str, str] = {}
    for items_file in sorted(corpus_dir.glob("*items*.jsonl")):
        for line in items_file.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            item = json.loads(line)
            fields = item.get("fields") or {}
            items_text[item.get("row_id") or ""] = norm(
                " ".join(str(v) for v in fields.values() if v))

    stated: dict[tuple, list[str]] = {}

    def record(subject, predicate, obj, row_id):
        key = (norm(subject), predicate, norm(obj))
        stated.setdefault(key, []).append(items_text.get(row_id or "", ""))

    for verdicts_file in sorted(list(corpus_dir.glob("verdicts*.json"))
                                + list(corpus_dir.glob("*results*.jsonl"))):
        try:
            if verdicts_file.suffix == ".json":
                payload = json.loads(verdicts_file.read_text(encoding="utf-8"))
                rows = payload.get("verdicts", [])
            else:
                rows = []
                for line in verdicts_file.read_text(encoding="utf-8").splitlines():
                    if not line.strip():
                        continue
                    row = json.loads(line)
                    try:
                        body = json.loads(row.get("body") or "")
                        for item in body.get("items", []):
                            item["row_id"] = row.get("row_id")
                            rows.append(item)
                    except (ValueError, TypeError):
                        continue
        except (ValueError, OSError):
            continue
        for verdict in rows:
            row_id = verdict.get("row_id")
            for mention in verdict.get("mentions", []):
                subject = (mention.get("canonical_label_hypothesis")
                           or mention.get("surface") or "")
                for rel in (mention.get("relation_hypotheses") or []):
                    obj = rel.get("object_label_hypothesis") or ""
                    if subject and obj:
                        record(subject, rel.get("predicate"), obj, row_id)

    # ------------------------------------------------------------------
    # The verdict per edge.
    # ------------------------------------------------------------------
    grounded, corroborated, demote, unmatched = [], [], [], []
    for edge in edges:
        s_label = edge["subject_label"] or ""
        o_label = edge["object_label"] or ""
        key = (norm(s_label), edge["predicate_key"], norm(o_label))
        entries = stated.get(key)
        row = {"edge_id": str(edge["edge_id"]),
               "subject": s_label, "predicate": edge["predicate_key"],
               "object": o_label, "subject_key": edge["subject_key"],
               "object_key": edge["object_key"]}
        if entries is None:
            # No corpus statement found (label drift, older lane) — leave
            # standing: an audit that cannot see the witness does not rule.
            unmatched.append(row)
            continue
        if any(norm(o_label) in text for text in entries if text):
            grounded.append(row)
            continue
        reference = claims_reference(entity_ids(s_label), entity_ids(o_label))
        if reference:
            corroborated.append({**row, "wikidata": reference})
        else:
            demote.append(row)

    out_path.write_text(json.dumps({
        "grounded": grounded, "corroborated": corroborated,
        "demote": demote, "unmatched_left_standing": unmatched},
        ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps({"edges": len(edges), "grounded": len(grounded),
                      "corroborated": len(corroborated),
                      "demote": len(demote),
                      "unmatched_left_standing": len(unmatched),
                      "out": str(out_path)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
