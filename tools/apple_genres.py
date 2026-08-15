#!/usr/bin/env python3
"""Apple's genre tree, which is where our genre vocabulary should come from.

**Why this exists.** Measured 2026-08-15 across the 931 artists already in the
catalogue: 45 distinct genre strings, **24 reach a `genre:` concept and 21 do
not** — `bollywood` (10 artists), `indian pop` (6), `indie rock` (5), `indie
pop` (4), `chinese hip hop` (3), then `afrobeats`, `britpop`, `french pop`,
`chinese rock`, `latin`, `bengali`, `big band`, `downtempo` and the rest. Our
genre vocabulary is a hand-written subset of Apple's, so most of what Apple says
about somebody's library lands nowhere, and an artist whose only genre is
unmatched gets no parent — which is what puts a term under "Other", or under the
`hub:music` fallback rather than its genre.

Hand-authoring the missing ones does not fix it, because the next library names
a genre nobody anticipated. Apple already publishes the tree, so this takes it.

**The tree is per storefront, and that is the whole design.** Measured before
this was written:

    us/genres            -> 19 genres under Music. No J-Pop, no Bollywood.
    jp/genres?l=en-US    -> J-Pop, Anime, Enka, Kayokyoku — in English
    tw/genres?l=en-GB    -> Mandopop, C-Pop, Cantopop
    all 167 storefronts  -> **57 distinct genres**, with parents

So a single storefront answers a fraction of the vocabulary and the union
answers most of it: `African -> Afrobeats, Amapiano`; `Indian -> Bollywood,
Indian Pop, Regional Indian`; `Pop -> K-Pop, J-Pop, Mandopop, Cantopop`;
`Brazilian -> Samba, Bossa Nova, MPB, Forró`. Crawling ids instead finds 22,
because most genres are simply absent from the `us` catalogue.

**Asked in English, from every storefront.** `l=` takes a language tag the
storefront supports, and all 167 support one beginning `en`, so the names come
back as the English strings every table in `music_dictionary.py` already holds —
`'J-Pop'` resolves and `'j-pop'` does not. This is why `apple_catalog.py` pins
`STOREFRONT = "us"` and why that pin cannot simply be widened: without `l=`, a
`tw` storefront answers `華語流行` where `Mandopop` is wanted.

**Some parents are storefront-specific too.** `Bollywood`'s parent id `1262`
answers 404 from `us` and `gb`; it exists only where its children do. So a
missing parent is fetched from a storefront that listed one of its children,
rather than assumed or dropped — a genre whose parent is missing would be a
floating node, which is the defect this file exists to remove.

**The private key never enters this process**, exactly as in
`apple_catalog.py`: a developer token is read from the environment, already
minted.

    export APPLE_MUSIC_DEVELOPER_TOKEN=eyJ...
    python3 tools/apple_genres.py            # summary to stderr, JSON to stdout
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

# **Imported rather than copied**, for the reason `apple_catalog.py` gives at
# length: an alias only matches if its stored `normalized_label` is
# byte-identical to what the resolver computes, and `0184` is what that costs
# when it is not. Genre names carry punctuation Apple chose — `Hip-Hop/Rap`,
# `R&B/Soul`, `Children’s Music` with a typographic apostrophe — so this is not
# a hypothetical.
sys.path.insert(
    0,
    os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "semantic", "src",
    ),
)

from written_ontology.normalize import normalize_text  # noqa: E402

APPLE = "https://api.music.apple.com/v1"

# **The root, and the whole of how a non-music branch is refused.** Apple files
# podcasts, audiobooks and app categories in the same id space — `drama`,
# `fiction literature`, `military history` and `spoken word` all reached our
# artists' `genreNames` from such rows. A genre is ours only if its ancestry
# reaches Music, which is positive recognition rather than a list of things to
# exclude, and so cannot fall out of date.
MUSIC_GENRE_ID = "34"


class GenresUnavailable(RuntimeError):
    """No usable developer token, distinguished so a caller can decline."""


def developer_token() -> str:
    token = (os.environ.get("APPLE_MUSIC_DEVELOPER_TOKEN") or "").strip()
    if not token:
        raise GenresUnavailable("APPLE_MUSIC_DEVELOPER_TOKEN is unset")
    return token


def _get(token: str, path: str) -> dict[str, Any] | None:
    """`None` for a 404, which is an ordinary answer here rather than a failure.

    A storefront that does not carry a genre says so with a 404, and the crawl
    depends on asking questions whose answer is often no. A 401 is left to raise:
    an expired token must not read as a small tree.
    """
    request = urllib.request.Request(
        f"{APPLE}/{path}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def english_storefronts(token: str) -> dict[str, str]:
    """Every storefront, paired with a language tag that answers in English.

    All 167 supported one when measured, but the tag differs — `en-US` in Japan,
    `en-GB` across most of Europe — so it is read from the storefront rather than
    guessed. A storefront with no English tag is skipped instead of being asked
    in a language whose strings nothing downstream holds.
    """
    body = _get(token, "storefronts?limit=200") or {}
    fronts: dict[str, str] = {}
    for item in body.get("data", []):
        tags = (item.get("attributes") or {}).get("supportedLanguageTags") or []
        english = next((tag for tag in tags if tag.lower().startswith("en")), None)
        if english:
            fronts[item["id"]] = english
    return fronts


def fetch_tree(token: str, storefronts: dict[str, str] | None = None
               ) -> dict[str, dict[str, Any]]:
    """The union of every storefront's genres, keyed by Apple's id.

    **First answer wins for the name, and it does not matter which.** The `l=`
    tag makes every storefront answer in English, so two storefronts naming one
    id agree; the union is about *coverage*, not about reconciling disagreements.
    """
    storefronts = storefronts if storefronts is not None else english_storefronts(token)
    tree: dict[str, dict[str, Any]] = {}
    seen_in: dict[str, str] = {}

    for storefront, language in sorted(storefronts.items()):
        query = urllib.parse.urlencode({"l": language})
        body = _get(token, f"catalog/{storefront}/genres?{query}")
        if body is None:
            continue
        for item in body.get("data", []):
            attributes = item.get("attributes") or {}
            name = (attributes.get("name") or "").strip()
            if not name:
                continue
            genre_id = str(item["id"])
            seen_in.setdefault(genre_id, storefront)
            tree.setdefault(genre_id, {
                "name": name,
                "parent_id": (str(attributes["parentId"])
                              if attributes.get("parentId") is not None else None),
            })

    # **Missing parents, fetched where their children live.** `Bollywood`'s
    # parent `1262` is absent from `us` and `gb` entirely; asking the storefront
    # that listed the child is the only way to learn its name, and without it the
    # child would be minted with a parent that does not exist.
    for _ in range(4):  # a chain of unlisted ancestors, bounded rather than while-true
        missing = {entry["parent_id"] for entry in tree.values()
                   if entry["parent_id"] and entry["parent_id"] not in tree}
        if not missing:
            break
        for parent_id in sorted(missing):
            child = next((gid for gid, entry in tree.items()
                          if entry["parent_id"] == parent_id), None)
            storefront = seen_in.get(child or "", "us")
            language = storefronts.get(storefront, "en-US")
            query = urllib.parse.urlencode({"l": language})
            body = _get(token, f"catalog/{storefront}/genres/{parent_id}?{query}")
            if body is None:
                continue
            for item in body.get("data", []):
                attributes = item.get("attributes") or {}
                tree.setdefault(str(item["id"]), {
                    "name": (attributes.get("name") or "").strip(),
                    "parent_id": (str(attributes["parentId"])
                                  if attributes.get("parentId") is not None else None),
                })
                seen_in.setdefault(str(item["id"]), storefront)
    return tree


def music_genres(tree: dict[str, dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """Everything the music catalogue returned, minus Music itself.

    **The ancestry test this used to apply was wrong, and the measurement is
    why.** It kept only genres whose parents chain to `34`, on the theory that
    Apple files podcast and audiobook categories in the same id space. They are
    not reachable here: `catalog/{sf}/genres` is the *music* catalogue's
    endpoint, so a `drama` or `military history` string reaching an artist's
    `genreNames` comes from a podcast row in our own vault, never from this.
    What the test actually did was drop eleven real music genres —
    `Bollywood`, `Indian Pop`, `Regional Indian`, `Indian Classical`,
    `Devotional & Spiritual`, `Samba`, `Bossa Nova`, `MPB`, `Forró`,
    `Sertanejo`, `Baile Funk`.

    **Because Apple references two parents it does not expose.** `1262` (the
    Indian family) and `1122` (the Brazilian one) appear as `parentId` on those
    eleven and answer 404 from every storefront, including the ones carrying
    their children. So their ancestry cannot reach Music however far it is
    walked, and a genre is not dropped for that: `dangling_parents` reports it
    and the mint parents such a genre to `hub:music`, as it does a top-level one.
    Naming the missing parent ourselves was the alternative and is refused —
    inferring `Indian` from its children is exactly the kind of guess this whole
    file exists to avoid.

    Music itself is excluded because it is not a genre anybody is: it is the
    drawer the music terms sit in, and `hub:music` already exists for that.
    """
    return {genre_id: entry for genre_id, entry in tree.items()
            if genre_id != MUSIC_GENRE_ID}


def dangling_parents(tree: dict[str, dict[str, Any]]) -> dict[str, list[str]]:
    """Parent ids Apple names but does not expose, and who names them.

    Reported rather than swallowed: a new one appearing means a family of
    genres is about to parent to `hub:music` instead of to each other, and that
    is a thing to know rather than to discover from a heading.
    """
    # **Music is not dangling, it is substituted.** It is excluded from the mint
    # on purpose — `hub:music` is our word for it — so a child naming it as
    # parent is the ordinary top-level case rather than something to report.
    known = set(tree) | {MUSIC_GENRE_ID}
    orphans: dict[str, list[str]] = {}
    for entry in tree.values():
        parent = entry["parent_id"]
        if parent and parent not in known:
            orphans.setdefault(parent, []).append(entry["name"])
    return {parent: sorted(names) for parent, names in orphans.items()}


def shaped(tree: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    """Rows in the shape `ontology.external_entities` stores, sorted by id.

    The normalised form is computed here, in Python, for the reason at the top of
    this file. `parent_id` is left as Apple's id: the mint resolves it to
    whichever concept holds that id, which is ours where we already had the
    genre and the minted one otherwise.
    """
    rows = []
    for genre_id in sorted(tree, key=int):
        entry = tree[genre_id]
        payload = {
            "name": entry["name"],
            "normalized": normalize_text(entry["name"]),
            "parent_id": entry["parent_id"],
        }
        # **Hashed the way `catalogue.py` hashes an artist**, and the encoding
        # has to match or the same answer would hash two ways and re-store on
        # every run — `external_entities` is unique on
        # `(provider, external_id, payload_hash)`, so the hash is what makes an
        # unchanged answer a conflict rather than a duplicate.
        encoded = json.dumps(payload, sort_keys=True, ensure_ascii=False)
        rows.append({
            "external_id": genre_id,
            "payload_hash": hashlib.sha256(encoded.encode("utf-8")).hexdigest(),
            **payload,
        })
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--all", action="store_true",
        help="keep every branch, not only the music subtree",
    )
    parser.add_argument(
        "--storefront", action="append", default=None,
        help="crawl only these storefronts (repeatable); default is all of them",
    )
    args = parser.parse_args()

    token = developer_token()
    fronts = english_storefronts(token)
    if args.storefront:
        fronts = {sf: tag for sf, tag in fronts.items() if sf in set(args.storefront)}

    tree = fetch_tree(token, fronts)
    kept = tree if args.all else music_genres(tree)
    print(
        f"{len(fronts)} storefronts: {len(tree)} genres, {len(kept)} to mint",
        file=sys.stderr,
    )
    for parent, children in sorted(dangling_parents(kept).items()):
        print(
            f"  parent {parent} is named but not exposed; "
            f"{len(children)} genre(s) will parent to hub:music: "
            f"{', '.join(children)}",
            file=sys.stderr,
        )
    json.dump(shaped(kept), sys.stdout, ensure_ascii=False, indent=2)
    print(file=sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
