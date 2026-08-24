#!/usr/bin/env python3
"""Turn validated verdicts into a dictionary migration — terms, labels, merges.

**Two guards, both evidence-based, neither fuzzy.** This project has paid
twice for similarity matching (`exact_terms_only`; the constant fallback key
that merged nine artists into one concept), so nothing here compares strings
for closeness. A merge is written only where the model *stated* one:

  * **A relation is not a translation, when the subject is a party.** For the
    surface `WINTER` the model emitted `english_label: aespa` *and*
    `part_of_franchise -> aespa` in the same mention: membership, not a
    spelling, and merging would fold a person into her group. But the same
    shape appears on `路人超能100`, whose English identity *is* `Mob Psycho
    100`. The two are told apart by the subject — a person or group is never
    identical to what it belongs to, while a title tagged `anime` may be the
    same title tagged `franchise`. See `_is_membership`.
  * **Metadata is not a term.** `playlist=`, `rank=`, `shelf=` surfaces come
    from a column that means four different things by `data_type`; they are
    refused outright.

**Identity is resolved once, at the end, and may cross families.** A claim is
recorded as each mention states it and the canonical is chosen after the whole
corpus is read — because a link emitted on sight lands at a key a later
mention may never mint, and an `insert … select` that matches nothing is
indistinguishable from one that worked. That silence cost 38 groups, `路飛` +
`luffy` among them. The canonical is the best-attested row — labelled first,
then directly named, then most mentioned, then family rank — never simply the
`franchise` row, which is usually the stub a relation object created.

Everything else follows the dictionary's standing rules: the key is the
release-suffix-bare normalisation the worker uses, rows are never deleted, and
`origin` records how a term arrived without deciding whether it is true — an
object the model only *related* to arrives `inferred` and is promoted to
`extracted` the moment something names it directly.

    python3 tools/ris_emit_dictionary.py out/ris/verdicts.json 0306
"""
from __future__ import annotations

import collections
import json
import pathlib
import re
import sys
import unicodedata

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]

#: Mirrors `_RELEASE_SUFFIXES` in aws/worker/overlay.py. The dictionary keys
#: on a suffix-bare label so `love dive` and `love dive single` are one term.
RELEASE_SUFFIXES = (" - single", " - ep", " (single)", " (ep)",
                    " live version", " remastered", " single", " ep")

METADATA = re.compile(r"^(rank|playlist|shelf|station|position|index)\s*=", re.I)

#: Families whose root is a person or group outrank the works that name them,
#: so a cluster canonicalises on the entity rather than on its release.
PREFERENCE = {"person": 0, "group": 0, "franchise": 1, "organization": 1,
              "event": 2, "tour": 2, "activity": 3, "sport": 3,
              "idea": 4, "culture": 4, "concept": 4,
              "work": 5, "anime": 5, "book": 5, "game": 5,
              "music_work": 6, "album": 7}


def normalise(text: str) -> str:
    value = unicodedata.normalize("NFKC", (text or "").strip()).casefold()
    value = re.sub(r"\s+", " ", value)
    changed = True
    while changed:
        changed = False
        for suffix in RELEASE_SUFFIXES:
            if value.endswith(suffix) and len(value) > len(suffix):
                value = value[: -len(suffix)].strip()
                changed = True
    return value


def quote(text) -> str:
    return "'" + str(text).replace("'", "''") + "'"


#: Which family the object of each predicate belongs to — the same map
#: `_OBJECT_FAMILY` states in aws/worker/overlay.py:1103. Copied rather
#: than imported because that module needs psycopg and boto3 to load,
#: which this tool has no business requiring; if the two ever disagree,
#: the worker's is the one that governs.
_OBJECT_FAMILY_FOR = {
    "part_of_franchise": "franchise", "member_of_group": "group",
    "performed_by": "person", "composed_by": "person",
    "created_by": "person", "soundtrack_of": "work",
    "recording_of": "music_work", "played_for": "organization",
    "official_channel_of": "organization",
    "represented_team_in": "event", "located_in": "place",
}


#: Families that name *a party* rather than a title. The membership guard
#: turns on this: an English label that is also the object of a relation is a
#: claim of belonging rather than a spelling — but only when the two are
#: different kinds of thing.
PARTY = {"person", "group", "organization"}


def _is_membership(english_key: str, related: dict, family: str) -> bool:
    """Is this English label a group the term belongs to, or its own name?

    **The guard narrows rather than vanishes.** It exists for `WINTER`, where
    the model emitted `english_label: aespa` *and*
    `part_of_franchise -> aespa` together: merging would fold a person into
    her group, and 515 such refusals were measured. But the same shape appears
    on `路人超能100`, whose English identity *is* `Mob Psycho 100` and whose
    relation says the same thing — and refusing that left two cards for one
    franchise.

    The two are told apart by **the subject**, not the object — which took one
    wrong attempt to see. WINTER is a `person` and aespa a `group`, so a rule
    reading "the object is a party and the subject is not" fires on neither and
    refuses nothing. What actually separates them is that **a party is never
    identical to the thing it belongs to**: a person is not her group, whereas
    a title tagged `anime` may well be the same title tagged `franchise`.

    So: a person or a group naming something else is membership. A work, an
    album, an anime naming a franchise is that franchise under another family
    — which is what makes `BABYMONS7ER` (album) resolve to `BABYMONSTER` and
    `路人超能100` (anime) resolve to `Mob Psycho 100` (franchise).
    """
    predicate = related.get(english_key)
    if predicate is None:
        return False
    if family in PARTY:
        return True
    # `member_of_group` says membership whatever the families claim; it is the
    # one predicate whose whole meaning is "belongs to, is not".
    return predicate == "member_of_group"


def main() -> int:
    verdicts = json.loads(pathlib.Path(sys.argv[1]).read_text())
    number = sys.argv[2]

    terms: dict = {}
    links: set = set()
    #: Every row that claimed a given English identity, keyed by that identity.
    #: Resolved into links once, after the whole corpus is read, so a claim can
    #: land on a row that only a later mention minted.
    identity: dict = collections.defaultdict(set)
    edges: collections.Counter = collections.Counter()
    refused_relation = 0
    refused_metadata = 0
    #: How many labels the second pass repaired, read from the merged file
    #: rather than restated, so the header cannot claim a run that did not
    #: happen.
    relabel = (verdicts.get("relabel") or {}).get("native_replaced", 0)

    OBJECT_FAMILY = _OBJECT_FAMILY_FOR

    for verdict in verdicts["verdicts"]:
        # **Which lanes attested this term.** `presumed_terms.source_lanes`
        # exists for exactly one question — *is anything but a calendar saying
        # this* — and it has been `'{}'` on every row ever written, so the
        # question was answered by guessing. A term the calendar alone attests
        # is the shape private diary residue takes, and a predicate that can
        # see it is what lets a sweep key on evidence rather than on a name
        # matching a pattern. The lane is a fact; a regex over names is not.
        lane = verdict.get("source_code")
        for mention in verdict["mentions"]:
            family = mention.get("family_hypothesis")
            surface = mention.get("surface") or ""
            if not family or METADATA.match(surface.strip()):
                refused_metadata += 1
                continue

            english = mention.get("english_label")
            native = mention.get("original_label")
            canonical = mention.get("canonical_label_hypothesis") or surface
            key = normalise(canonical)
            if not key:
                continue

            record = terms.setdefault((key, family), {
                "canonical": canonical, "english": None, "native": None,
                "origin": "extracted", "mentions": 0, "lanes": set()})
            if lane:
                record["lanes"].add(lane)
            record["english"] = record["english"] or english
            record["native"] = record["native"] or native
            # **A row somebody's library actually named.** Even if this key
            # first appeared as a relation object, a direct mention promotes
            # it: the franchise inferred from a character becomes attested the
            # moment the franchise itself is named.
            record["origin"] = "extracted"
            record["mentions"] += 1

            # **Identity is claimed here and resolved once, at the end.** The
            # old code emitted a link the moment it saw one, at a key that may
            # never exist — `路飛`'s English is `Monkey D. Luffy`, no row is
            # keyed `monkey d. luffy`, and the insert matched nothing silently.
            # Recording the claim and choosing a canonical afterwards is what
            # lets `路飛` and `luffy` find each other rather than both reaching
            # for a row that was never minted.
            related = {normalise(r.get("object_label_hypothesis")): r.get("predicate")
                       for r in (mention.get("relation_hypotheses") or [])}
            surface_key = normalise(surface)
            english_key = normalise(english)
            if english_key and english_key != surface_key:
                if _is_membership(english_key, related, family):
                    refused_relation += 1
                else:
                    # Both the surface and the canonical claim this identity.
                    for claimant, label in ((surface_key, surface), (key, canonical)):
                        if not claimant:
                            continue
                        # **Keyed by the identity alone, never by family.**
                        # Keying `(english_key, family)` groups claimants per
                        # family, so `(路人超能100, anime)` and
                        # `(mob psycho 100, franchise)` never meet and the
                        # widening does nothing — measured: 0 cross-family
                        # links out of 1,894. The identity is the English name;
                        # the family is a tag the model put on one mention.
                        identity[english_key].add((claimant, family))
                        claimed = terms.setdefault((claimant, family), {
                            "canonical": label, "english": english,
                            "native": native, "origin": "extracted",
                            "mentions": 0, "lanes": set()})
                        if lane:
                            claimed["lanes"].add(lane)

            # **The object of a relation is a term too**, which is the rule
            # that lets a franchise be known the first time any character of
            # it is seen — but it arrives as evidence *about* a term rather
            # than a term this library attested, so it is `inferred` until
            # something names it directly. All 693 unlabelled `franchise` rows
            # and 1,465 unlabelled `person` rows in the last load were these,
            # and every one of them became a card showing raw text.
            for relation in (mention.get("relation_hypotheses") or []):
                predicate = relation.get("predicate")
                object_family = OBJECT_FAMILY.get(predicate)
                object_label = relation.get("object_label_hypothesis")
                object_key = normalise(object_label)
                if not (object_family and object_key) or object_key == key:
                    continue
                stub = terms.setdefault((object_key, object_family), {
                    "canonical": object_label, "english": None, "native": None,
                    "origin": "inferred", "mentions": 0, "lanes": set()})
                if lane:
                    stub["lanes"].add(lane)
                edges[(key, family, predicate, object_key, object_family)] += 1

    # ---------------------------------------------------------------------
    # One canonical per identity, chosen once the whole corpus is known
    # ---------------------------------------------------------------------
    #
    # **Chosen by evidence, not by family rank.** The obvious rule — prefer
    # `franchise` — picks the wrong row here: measured on the last load, the
    # franchise row is usually the stub a relation object created, carrying no
    # label at all, while `work` or `group` carries the English name. So the
    # order is: a row that has an English label, then one somebody's library
    # actually named, then the one named most often, then family rank, then id.
    # Family rank still decides between two equally attested rows, which is
    # where `franchise` beats `anime` for `Mob Psycho 100`.
    def _rank(member: tuple) -> tuple:
        record = terms.get(member) or {}
        return (0 if record.get("english") else 1,
                0 if record.get("origin") == "extracted" else 1,
                -int(record.get("mentions") or 0),
                PREFERENCE.get(member[1], 9),
                member[0])

    unresolved_identities = 0
    for english_key, claimants in identity.items():
        # The English-named row itself is a claimant when it exists, so an
        # identity whose own name was minted canonicalises on it.
        members = {m for m in claimants if m in terms}
        # The English-named row itself, in whichever families it exists.
        members |= {(k, f) for (k, f) in terms if k == english_key}
        if len(members) < 2:
            unresolved_identities += 1
            continue
        canonical_member = min(members, key=_rank)
        for member in members:
            if member != canonical_member:
                links.add((member, canonical_member))

    inferred = sum(1 for r in terms.values() if r['origin'] == 'inferred')
    out: list[str] = [f"""-- {number} — the RIS corpus enters the dictionary: terms, labels, merges.
--
-- {len(terms)} terms extracted from the full distillation on a lab GPU (one
-- A100 80GB per shard, prompt v14), then passed a second time by
-- `tools/ris_relabel.py` for the {relabel} terms whose native label merely
-- echoed the script it was written in. Before this the dictionary held 1,000
-- terms and 14 English labels.
--
-- {len(links)} merges are written, each one stated by the model rather than
-- guessed at by comparing strings: this project has paid twice for similarity
-- matching and does not do it here.
--
-- **The refusals are what make the merges trustworthy, and they are counted
-- rather than assumed.** {refused_relation} merges were refused as membership:
-- the English label was also the object of a relation the same mention
-- emitted, *and the subject was a person or a group*. For `WINTER` the model
-- said `english_label: aespa` and `part_of_franchise -> aespa` together, which
-- asserts belonging and would fold a person into her group. The subject test
-- is what lets `路人超能100` through — a title tagged `anime` may be the same
-- title tagged `franchise`, while a person is never her band.
-- {refused_metadata} surfaces were refused as metadata (`playlist=`, `rank=`,
-- `shelf=`); that count is zero here because `tools/ris_build_items.py` now
-- routes the legacy `detail` column by what it means per `data_type`, so the
-- metadata never reaches the model. The filter stays because that routing is
-- per-source and the next source added will not have it.
--
-- **{inferred} rows arrive `inferred`.** They are the objects of relations —
-- a franchise known from one of its characters — and carry no label because
-- nothing named them directly. The last load minted them `extracted`, which
-- put 693 unlabelled `franchise` rows and 1,465 unlabelled `person` rows onto
-- the review surface as cards showing raw text.
--
-- Nothing here is deleted or overwritten: a term already present keeps its
-- row, and a label already recorded wins over this one.

insert into semantic_private.presumed_terms
  (normalized_label, family, canonical_label, english_label, original_label,
   origin, source_lanes)
values"""]

    rows = []
    for (key, family), record in sorted(terms.items()):
        lanes = "array[{}]::text[]".format(
            ", ".join(quote(name) for name in sorted(record.get("lanes") or ()))
        ) if record.get("lanes") else "'{}'"
        rows.append("  ({}, {}, {}, {}, {}, {}, {})".format(
            quote(key), quote(family), quote(record["canonical"][:512]),
            quote(record["english"][:512]) if record["english"] else "null",
            quote(record["native"][:512]) if record["native"] else "null",
            quote(record["origin"]), lanes))
    out.append(",\n".join(rows))
    out.append("""on conflict (normalized_label, family) do update
   set last_seen_at = now(),
       english_label = coalesce(semantic_private.presumed_terms.english_label,
                                excluded.english_label),
       original_label = coalesce(semantic_private.presumed_terms.original_label,
                                 excluded.original_label),
       -- **The incoming value wins, and it is already the promoted one.**
       -- The emitter reads the whole corpus before writing: a key that any
       -- mention named directly is `extracted` whatever else related to it,
       -- so `excluded.origin` is the maximum over this corpus rather than one
       -- row's opinion.
       --
       -- Preserving the stored value instead — promote, never demote — reads
       -- as the safer rule and is why the first attempt at this changed
       -- nothing: `0307` had already written all 2,158 stubs as `extracted`,
       -- so the correction could never land. A re-emission of the same corpus
       -- is a *correction*, and a rule that can only ever add is a rule that
       -- cannot fix anything.
       origin = excluded.origin,
       -- **Lanes union; they never replace.** A term this corpus saw only in a
       -- calendar may have been seen in a library by an earlier load, and the
       -- question `source_lanes` answers is *has anything but a calendar ever
       -- attested this* — which a replacement would answer with whichever run
       -- was most recent. `array_agg(distinct)` over the concatenation is the
       -- set union, ordered so a replay writes the same row.
       source_lanes = (
         select coalesce(array_agg(distinct lane order by lane), '{}')
           from unnest(semantic_private.presumed_terms.source_lanes
                       || excluded.source_lanes) as lane
          where lane is not null and lane <> '');
""")

    out.append("""-- The merges. 0301's trigger flattens chains and refuses cycles.
--
-- **Each side names its own family, and they may differ.** The old form bound
-- both ends to the mention's single `family_hypothesis`, so
-- `(路人超能100, anime)` could only ever look for `Mob Psycho 100` *in family
-- anime* — a row nothing mints — and the `insert … select` wrote zero rows
-- with no error. 1,710 identities were split across families that way, and 38
-- groups (`路飛` + `luffy`, `yujimin` + `yujin` + `최유진`) were lost to the
-- silent miss.
--
-- **And the count is checked.** A link statement that matches nothing is
-- indistinguishable from one that worked, which is exactly how those groups
-- disappeared; the block below counts what landed and raises if a corpus that
-- expected merges produced none.""")
    out.append("do $$\ndeclare\n  merged integer := 0;\n  n integer;\nbegin")
    for (variant, vfam), (canonical, cfam) in sorted(links):
        out.append(
            "  insert into semantic_private.presumed_term_links "
            "(variant_term_id, canonical_term_id, basis, evidence)\n"
            "  select v.id, c.id, 'label_pair', "
            "jsonb_build_object('source', 'ris_v15')\n"
            "    from semantic_private.presumed_terms v, "
            "semantic_private.presumed_terms c\n"
            f"   where v.normalized_label = {quote(variant)} "
            f"and v.family = {quote(vfam)}\n"
            f"     and c.normalized_label = {quote(canonical)} "
            f"and c.family = {quote(cfam)}\n"
            "     and v.id <> c.id and v.canonical_term_id is null\n"
            "     and coalesce(c.canonical_term_id, c.id) <> v.id;\n"
            "  get diagnostics n = row_count; merged := merged + n;")
    out.append(f"""  raise notice '{number}: % of {len(links)} merges landed', merged;
  -- **Zero is only a failure the first time.** A link statement that matches
  -- nothing is indistinguishable from one that worked — that silence lost 38
  -- identity groups, `路飛` + `luffy` among them — so a corpus that emitted
  -- merges and landed none must raise. But re-applying the same corpus lands
  -- none *because the rows are already variants*, which is success. The two
  -- are told apart by whether this load's links exist at all.
  if {len(links)} > 0 and merged = 0 and not exists (
       select 1 from semantic_private.presumed_term_links
        where evidence ->> 'source' = 'ris_v15') then
    raise exception
      '{number}: {len(links)} merges were emitted and none matched a row';
  end if;
end;
$$;""")

    out.append("\n-- The relations the model stated. Presumed, never traversed.")
    for (skey, sfam, predicate, okey, ofam), count in sorted(edges.items()):
        out.append(
            "insert into semantic_private.presumed_term_relations "
            "(subject_term_id, predicate, object_term_id, evidence, observed_count)\n"
            f"select s.id, {quote(predicate)}, o.id, "
            "jsonb_build_object('source', 'ris_v14'), " + str(count) + "\n"
            "  from semantic_private.presumed_terms s, "
            "semantic_private.presumed_terms o\n"
            f" where s.normalized_label = {quote(skey)} and s.family = {quote(sfam)}\n"
            f"   and o.normalized_label = {quote(okey)} and o.family = {quote(ofam)}\n"
            "   and s.id <> o.id\n"
            "on conflict (subject_term_id, predicate, object_term_id) do update\n"
            # **Set, never add.** The emitter counts every occurrence across
            # the whole corpus before writing, so the incoming value is already
            # the total for this corpus — adding it to what is stored counts
            # the same evidence again for every re-application. `0307`, `0317`
            # and `0319` are the same corpus applied three times, and every one
            # of the 6,990 edges reads 3× its true count: the corpus says
            # `luffy -> one piece` once and the database said three.
            #
            # `guard_presumed_term_relation_change` permits an update only
            # where the count does not fall, so a genuine correction downward
            # is `0322`'s job and not this statement's.
            "   set observed_count = greatest("
            "semantic_private.presumed_term_relations.observed_count, "
            "excluded.observed_count);")

    out.append(f"""
do $$
declare
  n integer;
begin
  select count(*) into n from semantic_private.presumed_terms;
  raise notice '{number}: % terms in the dictionary', n;
  select count(*) into n from semantic_private.presumed_terms
   where english_label is not null;
  raise notice '{number}: % carry an English label', n;
  select count(*) into n from semantic_private.presumed_terms
   where canonical_term_id is not null;
  raise notice '{number}: % defer to a canonical', n;
  select count(*) into n from semantic_private.presumed_term_relations;
  raise notice '{number}: % relations recorded', n;
end;
$$;
""")

    path = (REPOSITORY / "supabase" / "migrations"
            / f"{number}_the_ris_corpus_enters_the_dictionary.sql")
    path.write_text("\n".join(out) + "\n")
    print(json.dumps({"terms": len(terms), "merges": len(links),
                      "relations": len(edges),
                      "refused_as_relation": refused_relation,
                      "refused_as_metadata": refused_metadata,
                      "migration": str(path)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
