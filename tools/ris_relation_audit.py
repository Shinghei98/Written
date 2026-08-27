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
       (select array_agg(distinct l.label) from ontology.concept_labels l
         where l.concept_id = sc.id and l.status = 'active') as subject_labels,
       (select array_agg(distinct l.label) from ontology.concept_labels l
         where l.concept_id = oc.id and l.status = 'active') as object_labels
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


_CACHE_PATH = pathlib.Path.home() / ".written" / "wikidata_cache.json"
try:
    _CACHE = json.loads(_CACHE_PATH.read_text())
except Exception:  # noqa: BLE001
    _CACHE = {}


def _cache_put(key: str, value) -> None:
    _CACHE[key] = value
    try:
        _CACHE_PATH.parent.mkdir(exist_ok=True)
        _CACHE_PATH.write_text(json.dumps(_CACHE))
    except Exception:  # noqa: BLE001
        pass


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


def entity_ids(label: str) -> list[str] | None:
    """None means the lookup FAILED; [] means it worked and found nothing.
    The distinction is the audit's own rule: an audit that cannot see the
    witness does not rule — the first run demoted true relations because
    429s were silently read as refutations."""
    cached = _CACHE.get("ent:" + norm(label))
    if cached is not None:
        return cached
    time.sleep(1.0)
    try:
        found = _api({"action": "wbsearchentities", "language": "en",
                      "type": "item", "limit": 5, "search": label})
    except Exception:  # noqa: BLE001 - failure, distinct from absence
        return None
    ids = [hit["id"] for hit in found.get("search", [])
           if norm(hit.get("label") or "") == norm(label)
           or norm(hit.get("match", {}).get("text") or "") == norm(label)]
    _cache_put("ent:" + norm(label), ids)
    return ids


def claims_reference(qids_a: list[str], qids_b: list[str]):
    """(found, reference): found=False means the check could not run."""
    if not qids_a or not qids_b:
        return True, None
    time.sleep(1.0)
    try:
        entities = _api({"action": "wbgetentities", "props": "claims",
                         "ids": "|".join((qids_a + qids_b)[:10])})
    except Exception:  # noqa: BLE001 - the check did not run
        return False, None
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
                    return True, f"{qid}->{value.get('id')}"
    return True, None


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
    grounded, corroborated, demote = [], [], []
    unmatched, unverifiable, ambiguous_identity = [], [], []
    for edge in edges:
        s_labels = [l for l in (edge["subject_labels"] or []) if l]
        o_labels = [l for l in (edge["object_labels"] or []) if l]
        row = {"edge_id": str(edge["edge_id"]),
               "subject": (s_labels or ["?"])[0],
               "predicate": edge["predicate_key"],
               "object": (o_labels or ["?"])[0],
               "subject_key": edge["subject_key"],
               "object_key": edge["object_key"]}
        entries = None
        for sl in s_labels:
            for ol in o_labels:
                found = stated.get((norm(sl), edge["predicate_key"], norm(ol)))
                if found is not None:
                    entries = (entries or []) + found
        if entries is None:
            unmatched.append(row)
            continue
        if any(any(norm(ol) in text for ol in o_labels)
               for text in entries if text):
            grounded.append(row)
            continue
        s_ids = entity_ids(s_labels[0]) if s_labels else []
        o_ids = entity_ids(o_labels[0]) if o_labels else []
        if s_ids is None or o_ids is None:
            unverifiable.append(row)
            continue
        found, reference = claims_reference(s_ids, o_ids)
        if not found:
            unverifiable.append(row)
        elif reference:
            corroborated.append({**row, "wikidata": reference})
        elif len(s_ids) == 1 and len(o_ids) == 1:
            # **Only a uniquely resolved pair may demote** — the asa/ruka
            # lesson: a short name matching several namesakes means the
            # check may have examined the wrong witness, and an audit
            # that saw the wrong witness must not rule.
            demote.append({**row, "subject_qid": s_ids[0],
                           "object_qid": o_ids[0]})
        else:
            ambiguous_identity.append({**row, "subject_candidates": len(s_ids),
                                       "object_candidates": len(o_ids)})

    # ------------------------------------------------------------------
    # Triangulation: an ambiguous name whose OTHER wire corroborated has
    # a pinned identity — the QID that verified IS our catalogue's
    # referent (Lyn is the entity Wikidata credits for Persona). Re-run
    # the held checks against the pinned entity; unique by construction.
    # ------------------------------------------------------------------
    pinned: dict[str, str] = {}
    for row in corroborated:
        qa, qb = (row.get("wikidata") or "->").split("->")
        if qa:
            pinned.setdefault(row["subject_key"], qa)
        if qb:
            pinned.setdefault(row["object_key"], qb)
    still_ambiguous = []
    for row in ambiguous_identity:
        s_pin = pinned.get(row["subject_key"])
        o_labels_row = row.get("object")
        o_ids = entity_ids(o_labels_row) if o_labels_row else []
        if s_pin and o_ids is not None and len(o_ids) == 1:
            found, reference = claims_reference([s_pin], o_ids)
            if not found:
                unverifiable.append(row)
            elif reference:
                corroborated.append({**row, "wikidata": reference,
                                     "via": "triangulated"})
            else:
                demote.append({**row, "subject_qid": s_pin,
                               "object_qid": o_ids[0],
                               "via": "triangulated"})
            continue
        still_ambiguous.append(row)
    ambiguous_identity = still_ambiguous

    out_path.write_text(json.dumps({
        "grounded": grounded, "corroborated": corroborated,
        "demote": demote, "unmatched_left_standing": unmatched,
        "unverifiable_left_standing": unverifiable,
        "ambiguous_identity_left_standing": ambiguous_identity},
        ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps({"edges": len(edges), "grounded": len(grounded),
                      "corroborated": len(corroborated),
                      "demote": len(demote),
                      "unmatched_left_standing": len(unmatched),
                      "unverifiable_left_standing": len(unverifiable),
                      "ambiguous_identity_left_standing": len(ambiguous_identity),
                      "out": str(out_path)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
