#!/usr/bin/env python3
"""YouTube's provider topics, mapped onto our concepts and expanded from Wikidata.

**This is the ungated half of the YouTube ontology, and the reason it is ungated
is what the whole file is arranged around.** `topicDetails.topicCategories`
arrives as Wikipedia URLs — YouTube has *stated* the topic — so translating one
onto a concept we own, and dereferencing it against a public knowledge graph, is
reading a supplied label. It is `provider_topic`, which is absent from the
approval booleans in `ontology.youtube_policy_approvals` for exactly that reason.
Producing a category from a title is the other thing, is `written_title_tag`, is
gated behind `allow_title_tags`, and is not in this file.

**Measured before it was built, against 639 real rows.** The premise this began
with — that YouTube is overwhelmingly underlabeled — is false, and the true shape
is what makes this tool worth having:

    liked_video    467 rows,   0.0% unlabelled  (451 topics, 467 category_id)
    subscription   146 rows,   5.5% unlabelled  (138 topics)
    playlist_item   25 rows, 100.0% unlabelled
    playlist         1 row,  100.0% unlabelled

So coverage is not the problem. **Depth is**: 639 rows collapse onto **28
distinct topics, five of which carry 80% of them** — `Music_of_Asia` alone is
24%, `Music` 19%, `Pop_music` 18%. YouTube labels nearly everything and labels it
very coarsely, so the gain here comes from expanding a small vocabulary well,
not from labelling a long tail.

**Nine of the twenty-four map onto concepts that already exist** — `genre:pop`,
`genre:electronic`, `genre:hip_hop`, `genre:classical`, `hub:music`,
`hub:film_video`, `hub:arts_live`, `hub:ideas_learning`, `hub:food_drink`. Reusing
them rather than minting `concept:pop_music` beside `genre:pop` is the whole
point: a second key for one idea splits the evidence for it in two, and
`Ontology`'s music work already paid for that lesson under a different name.

Run:

    python3 tools/youtube_topics.py --fetch     # resolve QIDs, writes the cache
    python3 tools/youtube_topics.py --emit      # print the migration
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
import urllib.parse
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
CACHE = HERE / "youtube_topics_wikidata.json"
USER_AGENT = "Written-Ontology/0.1 (https://written-stl.com; hello@written-stl.com)"

# **The refused list, and it is a copy with a job rather than a duplication.**
# `Ontology.refusedTopics` (Written/Services/Ontology.swift:729) drops these on
# the device; this drops them before they can become a concept. A protected
# characteristic arriving as a content tag is the failure both exist to stop, and
# it has to be refused at every point that could mint something — a concept
# authored here would outlive any client-side filter.
#
# Measured on the real corpus: Health 21 rows, Society 10, Religion 6,
# Politics 3. Forty rows, and none of them become anything.
REFUSED = {"Religion", "Politics", "Health", "Military", "Society"}

# ---------------------------------------------------------------------------
# The hand-authored half.
#
# **Every row here is a translation, and none is a judgement about content.**
# The left side is a string YouTube emitted; the right is the concept we already
# call that thing. Where no concept exists, one is minted — and the `broader` key
# is what stops a new concept being an orphan, since a term with no parent
# contributes to nothing that reasons over the graph.
#
# `None` for a concept key means *recognised and deliberately not carried*: it is
# not the same as absent, and keeping the row documents the decision.
# ---------------------------------------------------------------------------

Topic = tuple[str, str, str, str | None]  # key, kind, preferred label, broader

TOPIC_CONCEPTS: dict[str, Topic | None] = {
    # --- already ours; mapped, not minted -----------------------------------
    "Music":                    ("hub:music",           "hub",    "Music",             None),
    "Pop_music":                ("genre:pop",           "genre",  "Pop",               "hub:music"),
    "Electronic_music":         ("genre:electronic",    "genre",  "Electronic",        "hub:music"),
    "Hip_hop_music":            ("genre:hip_hop",       "genre",  "Hip hop",           "hub:music"),
    "Classical_music":          ("genre:classical",     "genre",  "Classical",         "hub:music"),
    "Knowledge":                ("hub:ideas_learning",  "hub",    "Ideas & learning",  None),
    "Food":                     ("hub:food_drink",      "hub",    "Food & drink",      None),
    "Film":                     ("hub:film_video",      "hub",    "Film & video",      None),
    "Video_game_culture":       ("hub:games_play",      "hub",    "Games & play",      None),

    # --- recognised and deliberately not carried ----------------------------
    #
    # **Measured on the real corpus, not judged by eye.** Each of these is a
    # top-of-tree YouTube label that mostly rides along with a topic that
    # already says more, so carrying it adds rows and no information. The test
    # was how often the topic appears on a row that also carries a music topic:
    #
    #   Performing_arts       136 rows, 92% alongside music
    #   Hobby                  21 rows, 76%
    #   Entertainment         180 rows, 62%
    #   Lifestyle_(sociology)  92 rows, 36%
    #
    # against `Knowledge` at **0%** and `Technology` at 0%, which is why those
    # two are carried: they never ride along, so they are marking something.
    #
    # **`Performing_arts` is the one that would have done harm** rather than
    # merely added noise. It was mapped to `hub:arts_live`, so at 92% co-tagging
    # it would have read a K-pop video as evidence of an interest in live
    # theatre — a wrong claim about a person, arrived at from a correct label.
    # A co-tag is not a signal, and the ones that look most like categories are
    # the ones worth measuring hardest.
    "Performing_arts":          None,
    "Entertainment":            None,
    "Lifestyle_(sociology)":    None,
    "Hobby":                    None,

    # --- minted, because nothing we own means this ---------------------------
    #
    # **`Music_of_Asia` is the single most valuable row in the file**, and not
    # because of its own meaning. It is 24% of the corpus and says almost
    # nothing on its own — but we already own `genre:k_pop`, `genre:j_pop`,
    # `genre:cantopop` and `genre:mandopop`, and nothing has ever said they are
    # the same family. Minting the parent lets one coarse provider label connect
    # to four specific genres somebody's music library already evidences.
    "Music_of_Asia":            ("genre:asian_music",   "genre",  "Asian music",       "hub:music"),
    "Independent_music":        ("genre:indie",         "genre",  "Indie",             "hub:music"),
    "Technology":               ("concept:technology",  "topic",  "Technology",        "hub:ideas_learning"),
    "Fashion":                  ("concept:fashion",     "topic",  "Fashion",           None),
    "Tourism":                  ("concept:tourism",     "topic",  "Travel",            "hub:places_cultures"),
    "Humour":                   ("concept:humour",      "topic",  "Comedy",            "hub:arts_live"),
    "Television_program":       ("medium:television",   "medium", "Television",        "hub:film_video"),

    # Game genres. `genre:video_game` exists and is a *music* genre — game
    # soundtracks — so these hang off `hub:games_play` instead. Two ideas that
    # would otherwise collide on one word.
    "Role-playing_video_game":  ("genre:role_playing_game",    "genre", "Role-playing games",   "hub:games_play"),
    "Action_game":              ("genre:action_game",          "genre", "Action games",         "hub:games_play"),
    "Action-adventure_game":    ("genre:action_adventure_game","genre", "Action-adventure games","hub:games_play"),
    "Strategy_video_game":      ("genre:strategy_game",        "genre", "Strategy games",       "hub:games_play"),
}

# **Edges the provider label licenses but does not itself state.** `Music_of_Asia`
# is YouTube's word; that K-pop is Asian music is Wikidata's and is not in
# dispute. These are `broader` (hierarchical, assertion-safe, one hop), so a
# K-pop listener reaches the parent and nothing reaches back down to claim they
# listen to Mandopop.
ASIAN_MUSIC_CHILDREN = ["genre:k_pop", "genre:j_pop", "genre:cantopop", "genre:mandopop"]

# **Concepts ontology version 0.3.0 already holds**, listed rather than detected.
# A key here gets a provider label and no new concept row; a key absent from it
# is minted. Getting this wrong in the generous direction is the expensive
# one — minting `concept:pop_music` beside the `genre:pop` a thousand music rows
# already point at splits the evidence for one idea across two keys, silently,
# and every score downstream is then computed on half of it.
#
# **This list rots and the tool cannot tell**, having no database access. Every
# key was checked against published version 0.3.0 by hand when it was written and
# all fifteen resolved. Re-run that before regenerating:
#
#   select k from (values ('hub:music'), …) t(k)
#    where not exists (select 1 from ontology.concepts c where c.concept_key = k);
#
# An unresolved key is silent, not loud: the edge insert joins on `concept_key`,
# so a typo produces no row and no error.
ALREADY_OURS = {
    "hub:music", "hub:arts_live", "hub:ideas_learning", "hub:food_drink",
    "hub:film_video", "hub:games_play", "hub:places_cultures",
    "genre:pop", "genre:electronic", "genre:hip_hop", "genre:classical",
    "genre:k_pop", "genre:j_pop", "genre:cantopop", "genre:mandopop",
}


def wikidata_qid(title: str) -> str | None:
    """The QID behind a Wikipedia article title, via the article itself.

    **The URL YouTube sent is the identifier**, so this is a dereference and not
    a search: no fuzzy matching, no best guess, and a title that resolves to
    nothing returns `None` rather than something plausible. That is the same line
    `domainForCreatorTag` draws between translating a label and guessing one.
    """
    api = "https://en.wikipedia.org/w/api.php?" + urllib.parse.urlencode({
        "action": "query", "prop": "pageprops", "ppprop": "wikibase_item",
        "titles": title, "format": "json", "redirects": "1",
    })
    # **Wikimedia refuses the default Python agent with a bare 403**, which reads
    # as the article being missing rather than as the request being rejected.
    # Their API etiquette asks for a descriptive agent with a contact.
    request = urllib.request.Request(api, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=20) as response:
        pages = json.load(response).get("query", {}).get("pages", {})
    for page in pages.values():
        qid = page.get("pageprops", {}).get("wikibase_item")
        if qid:
            return qid
    return None


def fetch() -> None:
    """Resolve every carried topic to a QID and cache it.

    Cached because the migration is generated more than once and Wikipedia should
    not be asked the same 24 questions each time — and because a generated
    migration whose contents depend on a live network call is not reproducible,
    which `0075` established as the shape these take.
    """
    resolved: dict[str, str | None] = {}
    for topic, concept in sorted(TOPIC_CONCEPTS.items()):
        if topic in REFUSED or concept is None:
            continue
        qid = wikidata_qid(topic.replace("_", " "))
        resolved[topic] = qid
        print(f"  {topic:28} -> {qid or '(unresolved)'}", file=sys.stderr)
    CACHE.write_text(json.dumps(resolved, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"\ncached {len(resolved)} topics to {CACHE.name}", file=sys.stderr)


def sql_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


FROM_VERSION = "0.3.0"
TO_VERSION = "0.4.0"

COPY_FORWARD = """
insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
select new_v.id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
from ontology.concept_revisions r
join ontology.versions old_v on old_v.id = r.ontology_version_id and old_v.version = '{old}'
cross join (select id from ontology.versions where version = '{new}') new_v
on conflict do nothing;

insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
select new_v.id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
from ontology.concept_labels l
join ontology.versions old_v on old_v.id = l.ontology_version_id and old_v.version = '{old}'
cross join (select id from ontology.versions where version = '{new}') new_v
on conflict do nothing;

insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
select new_v.id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
from ontology.concept_edges e
join ontology.versions old_v on old_v.id = e.ontology_version_id and old_v.version = '{old}'
cross join (select id from ontology.versions where version = '{new}') new_v
on conflict do nothing;

insert into ontology.motif_rules (
  id, ontology_version_id, rule_key, evidence_target_concept_id, output_concept_id,
  evidence_predicate_key, output_predicate_key, rule_kind,
  minimum_independence_groups, minimum_strength, configuration, status)
select gen_random_uuid(), new_v.id, m.rule_key, m.evidence_target_concept_id,
       m.output_concept_id, m.evidence_predicate_key, m.output_predicate_key,
       m.rule_kind, m.minimum_independence_groups, m.minimum_strength,
       m.configuration, m.status
from ontology.motif_rules m
join ontology.versions old_v on old_v.id = m.ontology_version_id and old_v.version = '{old}'
cross join (select id from ontology.versions where version = '{new}') new_v
on conflict do nothing;
"""


def emit() -> None:
    """Print the migration: new concepts, the provider labels, and the edges.

    **The YouTube topic string is stored as a `source_term` label, not as a
    concept name**, and that is the whole modelling decision. `Music_of_Asia` is
    a string YouTube emitted; `Asian music` is what we call the idea. Keeping
    them as label and concept means the resolver looks the provider's own word up
    directly — `concept_labels` is already indexed on `normalized_label` — while
    nothing user-facing ever shows YouTube's spelling.

    `provenance_type='provider'` says who supplied the term, and `external_ref`
    carries the QID and the article, so any one of these is checkable by hand
    without taking this tool's word for it. Both columns have existed since
    `0042` and this is their first real use.
    """
    if not CACHE.exists():
        sys.exit("no cache — run with --fetch first")
    qids: dict[str, str | None] = json.loads(CACHE.read_text(encoding="utf-8"))

    carried = {t: c for t, c in TOPIC_CONCEPTS.items() if c and t not in REFUSED}
    minted = {t: c for t, c in carried.items() if c[0] not in ALREADY_OURS}
    resolved = sum(1 for t in carried if qids.get(t))

    print(f"""-- YouTube provider topics, mapped onto our concepts.
--
-- Generated by `tools/youtube_topics.py --emit`. Do not hand-edit: change the
-- tool and regenerate, or the file and the rules it came from stop agreeing.
--
-- {len(carried)} topics carried, {resolved} with a Wikidata QID, {len(REFUSED)} refused.
--
-- **This is `provider_topic` and needs no approval.** The topics arrive as
-- Wikipedia URLs on `topicDetails.topicCategories` — YouTube states them — so
-- mapping one onto a concept is reading a supplied label. `written_title_tag`,
-- which is the inferring kind, is gated behind `allow_title_tags` and is not
-- here.
--
-- Measured before it was written: 639 real rows carry 28 distinct topics, five
-- of which cover 80% of them. The gain is depth on a small vocabulary, not
-- coverage of a long tail.
--
-- A published ontology version is immutable, so this mints {TO_VERSION} from
-- {FROM_VERSION}, copies it forward wholesale, adds the below, and publishes
-- last — publishing is also retiring, since only one version may be published.

begin;

insert into ontology.versions (id, version, parent_version_id, status, description, published_at)
select gen_random_uuid(), '{TO_VERSION}', v.id, 'draft',
       'YouTube provider topics mapped onto concepts.', null
from ontology.versions v where v.version = '{FROM_VERSION}'
on conflict (version) do nothing;
{COPY_FORWARD.format(old=FROM_VERSION, new=TO_VERSION)}""")

    print("create temporary table seed_concept (concept_key text primary key, "
          "preferred_label text not null, concept_kind text not null) on commit drop;")
    print("insert into seed_concept values")
    rows = [f"  ({sql_quote(k)}, {sql_quote(label)}, {sql_quote(kind)})"
            for _, (k, kind, label, _) in sorted(minted.items())]
    print(",\n".join(rows) + ";\n")

    print("create temporary table seed_label (concept_key text, label text, "
          "normalized_label text, external_ref jsonb) on commit drop;")
    print("insert into seed_label values")
    rows = []
    for topic, (key, _, _, _) in sorted(carried.items()):
        qid = qids.get(topic)
        ref = {"provider": "youtube", "wikipedia": topic}
        if qid:
            ref["wikidata"] = qid
        rows.append(f"  ({sql_quote(key)}, {sql_quote(topic)}, "
                    f"{sql_quote(topic.replace('_', ' ').lower())}, "
                    f"{sql_quote(json.dumps(ref, sort_keys=True))}::jsonb)")
    print(",\n".join(rows) + ";\n")

    print("create temporary table seed_edge (subject_key text, object_key text) "
          "on commit drop;")
    print("insert into seed_edge values")
    # **An edge is emitted only when one end is newly minted**, and the reason is
    # `concept_edges`' unique key: it includes `provenance_type`, so restating
    # `genre:pop broader hub:music` — which the music ontology already asserts as
    # `curated` — would not conflict. It would insert a *second* row saying the
    # same thing with `external` provenance, and anything counting edges would
    # count it twice. Verified against the published version: those four exist;
    # the four Asian-music ones do not.
    edges = {(k, broader) for _, (k, _, _, broader) in carried.items() if broader}
    edges |= {(child, "genre:asian_music") for child in ASIAN_MUSIC_CHILDREN}
    edges = {(s, o) for s, o in edges
             if s not in ALREADY_OURS or o not in ALREADY_OURS}
    rows = [f"  ({sql_quote(s)}, {sql_quote(o)})" for s, o in sorted(edges)]
    print(",\n".join(rows) + ";\n")

    print(f"""insert into ontology.concepts (id, concept_key)
select gen_random_uuid(), s.concept_key from seed_concept s
on conflict (concept_key) do nothing;

-- `inference_policy = 'inferable'`: every one of these is a topic YouTube
-- *stated* on the video. Reading is not inferring — the same distinction that
-- keeps `Ontology.classify` away from YouTube entirely.
insert into ontology.concept_revisions (
  ontology_version_id, concept_id, preferred_label, concept_kind,
  definition, sensitivity, inference_policy, status, metadata)
select v.id, c.id, s.preferred_label, s.concept_kind,
       'A topic YouTube stated on a video; never inferred from a title.',
       'ordinary', 'inferable', 'active', '{{}}'::jsonb
from seed_concept s
join ontology.concepts c on c.concept_key = s.concept_key
cross join (select id from ontology.versions where version = '{TO_VERSION}') v
on conflict (ontology_version_id, concept_id) do nothing;

-- **`source_term`, because that is exactly what these are.** The provider's own
-- string, kept so the resolver can look it up, and never shown to anybody.
insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status, external_ref)
select v.id, c.id, l.label, l.normalized_label, 'und',
       'source_term', 'provider', 1.0, 'active', l.external_ref
from seed_label l
join ontology.concepts c on c.concept_key = l.concept_key
cross join (select id from ontology.versions where version = '{TO_VERSION}') v
on conflict (ontology_version_id, concept_id, locale, normalized_label, label_type)
  do nothing;

-- `broader` is hierarchical, assertion-safe and one hop: a K-pop listener
-- reaches Asian music, and nothing reaches back down to claim they listen to
-- Mandopop.
insert into ontology.concept_edges (
  ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
  confidence, provenance_type, provenance, status)
select v.id, subject.id, 'broader', object.id, 1.0, 'external',
       '{{"source": "youtube_topics", "basis": "wikidata"}}'::jsonb, 'active'
from seed_edge e
join ontology.concepts subject on subject.concept_key = e.subject_key
join ontology.concepts object on object.concept_key = e.object_key
cross join (select id from ontology.versions where version = '{TO_VERSION}') v
on conflict do nothing;

update ontology.versions set status = 'retired'
 where version = '{FROM_VERSION}' and status = 'published';

update ontology.versions set status = 'published', published_at = now()
 where version = '{TO_VERSION}';

commit;""")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fetch", action="store_true", help="resolve QIDs from Wikipedia")
    parser.add_argument("--emit", action="store_true", help="print the migration")
    args = parser.parse_args()
    if args.fetch:
        fetch()
    elif args.emit:
        emit()
    else:
        parser.print_help()
