#!/usr/bin/env python3
"""Seed six synthetic accounts — full datasets, not six cards.

The discovery feed needs people to discover, and there is exactly one real
account. This writes six complete ones: auth user, profile, connections, music
and video records, health signals and calendar events, and finally the
`discovery_cards` row derived from all of it — so a synthetic person is built
the same way a real one is rather than being a card with nothing behind it.

    SUPABASE_SECRET_KEY=... python3 tools/seed_synthetic.py
    SUPABASE_SECRET_KEY=... python3 tools/seed_synthetic.py --wipe

**The secret key must never reach the app or this repo.** It bypasses row level
security completely, and RLS is the whole authorisation layer here — a copy of
that key is a copy of every account. It is read from the environment, has no
default, and is never printed. Run this from a shell, not from the app, and not
from anything that logs its environment.

The variable was `SUPABASE_SERVICE_ROLE_KEY` and is not any more, because
`service_role` keys were **disabled** on this project — the name described a
kind of credential that no longer exists. It kept working, which was the danger:
an `sb_secret_…` value sitting in a variable called `SERVICE_ROLE_KEY` quietly
misdescribes what it is, and confusing those two is what made the last rotation
harder than it needed to be. `tools/chat_e2e.py` uses the same name.

`--wipe` deletes the six synthetic auth users first, which cascades every table.
It matches on the seeded email domain and will not touch a real account.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import struct
import sys
import urllib.error
import urllib.request
import zlib
from datetime import datetime, timedelta, timezone

PROJECT_REF = "fwnezkbesjoazlpaflbq"
BASE = f"https://{PROJECT_REF}.supabase.co"

# Every synthetic account carries this domain, which is what makes `--wipe`
# safe: a real account can never match it.
SYNTHETIC_DOMAIN = "synthetic.written.invalid"

PEOPLE = ["Mina", "Joon", "Elise", "Tobias", "Priya", "Marcus"]

# School and bio, per person, in that order — the two fields `match_profile()`
# returns and the only ones on the dynamic profile that are not also on the
# discovery card. Without them a synthetic account's page has an empty gated
# half, which looks exactly like the function refusing the caller.
#
# Bios are written at or under `DistillViewModel.maximumBioLength` (30) because
# the sheet caps at the keyboard rather than on save; a seeded row longer than
# somebody could actually type would be a fixture the app cannot reproduce.
BIOGRAPHICS = [
    ("Washington University in St. Louis", "Always chasing good light"),
    ("Saint Louis University",             "Second breakfast fan"),
    ("Webster University",                 "I will beat you at Catan"),
    ("University of Missouri–St. Louis",   "Fixing a bike, badly"),
    ("Maryville University",               "Here for the dog park"),
    ("Fontbonne University",               "Ask me about bread"),
]

# Chosen per person rather than rolled, and one of them is not either.
#
# `seed_icebreaker` maps anything that is not `male` or `female` to *them*, so a
# random draw produced "ask them about Hilary Hahn" for Priya — correct about
# the data and arbitrary in the data, which reads as a bug to anyone who knows
# the name.
#
# **This is a fixture being deliberate, not the app guessing.** Written infers
# nothing about gender from a name and must not start: the icebreaker takes the
# pronoun from `public.users.sex`, which is the gender somebody *chose*, and the
# whole reason that column is not written by anything else is that HealthKit's
# biological sex was silently overwriting it. Fixing the fixture is not a licence
# to infer; it is the difference between test data that means something and test
# data that means nothing.
#
# `other` is kept on one account on purpose. *Them* is the branch every unmapped
# and null value falls to, it is the one most likely to be wrong on screen, and
# a pool where everybody is `male` or `female` would never exercise it.
GENDERS = ["female", "male", "female", "male", "female", "other"]

# Walkable from Central West End, which is the point — a discovery feed full of
# people three states away would say nothing about whether the feed works.
DISTRICTS = [
    "Central West End", "Forest Park Southeast", "The Grove",
    "Skinker–DeBaliviere", "DeBaliviere Place", "Botanical Heights",
    "Shaw", "Cortex", "Midtown", "Tower Grove East",
]

MUSIC_GENRES = [
    "K-pop", "J-pop", "C-pop", "Country", "Rock",
    "Pop", "Metal", "Musical", "Techno", "Classical",
]

VIDEO_CATEGORIES = [
    "Pets", "Sports", "Movies", "TV shows", "Stand-up comedy",
    "Self-help", "Startups", "Personal finance",
]

# Names to hang on the mix, so a record reads like something rather than
# "K-pop item 3". Two or three per bucket is enough: what the feed shows is the
# *subject*, and the subject is the artist or the channel.
ARTISTS = {
    "K-pop": ["SEVENTEEN", "LE SSERAFIM", "Tomorrow X Together"],
    "J-pop": ["Fujii Kaze", "Aimyon", "King Gnu"],
    "C-pop": ["Jay Chou", "Tanya Chua", "Eason Chan"],
    "Country": ["Zach Bryan", "Kacey Musgraves", "Tyler Childers"],
    "Rock": ["Fontaines D.C.", "IDLES", "Wet Leg"],
    "Pop": ["Caroline Polachek", "Chappell Roan", "Charli XCX"],
    "Metal": ["Gojira", "Sleep Token", "Knocked Loose"],
    "Musical": ["Hadestown", "Ride the Cyclone", "Sunday in the Park"],
    "Techno": ["Overmono", "Four Tet", "DJ Koze"],
    "Classical": ["Hilary Hahn", "Víkingur Ólafsson", "Kanneh-Mason"],
}

CHANNELS = {
    "Pets": ["Kitten Lady", "Lucky Ferals", "Rescue & Rehab"],
    "Sports": ["Men in Blazers", "Tifo Football", "JxmyHighroller"],
    "Movies": ["Every Frame a Painting", "Lessons from the Screenplay"],
    "TV shows": ["The Take", "Screen Rant Pitch Meetings"],
    "Stand-up comedy": ["Netflix Is A Joke", "Don't Tell Comedy"],
    "Self-help": ["Ali Abdaal", "Struthless", "Better Ideas"],
    "Startups": ["Y Combinator", "Starter Story", "Slidebean"],
    "Personal finance": ["The Plain Bagel", "Patrick Boyle", "Ben Felix"],
}

# The ontology domain each bucket maps to, so `interests` speaks the same
# language as Written/Services/Ontology.swift rather than a parallel vocabulary.
MUSIC_DOMAIN = "music"
# Sport *played*, from `health_sports` — never returned by `classify`, because a
# term list matched against a title cannot tell watching a sport from playing
# one. Matches `Ontology.Domain.playedSport`.
SPORT_DOMAIN = "playedSport"
VIDEO_DOMAINS = {
    "Pets": "science", "Sports": "spectatorSport", "Movies": "film",
    "TV shows": "film", "Stand-up comedy": "comedy", "Self-help": "learning",
    "Startups": "tech", "Personal finance": "learning",
}

CHRONOTYPES = [
    ("Early riser", 5 * 60 + 40), ("Morning person", 7 * 60 + 5),
    ("Steady starter", 8 * 60 + 20), ("Late riser", 10 * 60 + 15),
]

SPORTS = ["Running", "Climbing", "Cycling", "Swimming", "Yoga", "Tennis", None]

# One each of the first four, so the feed always has a musical-goer, a DJ, a
# raver and someone with a work thing — the four bookings that read most
# differently from one another.
CALENDAR_PLAN = [
    [("Hadestown at the Fox", "Ticketmaster")],
    [("Overmono — Delmar Hall", "Dice")],
    [("Warehouse rave, Cortex", "Eventbrite")],
    [("Q3 planning workshop", None)],
    [("Food pantry shift", None), ("Trail cleanup, Forest Park", None)],
    [],
]


def env_key() -> str:
    key = os.environ.get("SUPABASE_SECRET_KEY", "").strip()
    if not key:
        sys.exit(
            "SUPABASE_SECRET_KEY is not set.\n\n"
            "It bypasses row level security entirely, so it lives in your shell "
            "for the length of this run and nowhere else — not in the repo, not "
            "in the app, not in a file."
        )
    return key


def request(method: str, path: str, key: str, body=None, headers=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{BASE}{path}", data=data, method=method)
    req.add_header("apikey", key)
    req.add_header("Authorization", f"Bearer {key}")
    req.add_header("Content-Type", "application/json")
    for name, value in (headers or {}).items():
        req.add_header(name, value)
    try:
        with urllib.request.urlopen(req) as response:
            raw = response.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        # The body carries the reason; the status alone never says which
        # constraint or policy refused.
        sys.exit(f"{method} {path} failed: {error.code}\n{error.read().decode()}")


def upload(path: str, key: str, data: bytes, content_type: str) -> None:
    """Put raw bytes in Storage, which `request` cannot do — it speaks JSON only.

    `x-upsert` is belt and braces rather than load-bearing: every seed mints new
    user ids, so the paths are new too and a plain create would not collide.
    It costs nothing and means an interrupted run can be repeated.

    **Storage does not cascade**, which is the thing to remember here. Deleting
    an auth user takes every row that references it, in every table, and leaves
    the objects in the bucket untouched — they are not rows. `wipe` deletes them
    by hand for that reason; without it each reseed would abandon another
    thirty-six files under ids nothing points at any more.
    """
    req = urllib.request.Request(f"{BASE}{path}", data=data, method="POST")
    req.add_header("apikey", key)
    req.add_header("Authorization", f"Bearer {key}")
    req.add_header("Content-Type", content_type)
    req.add_header("x-upsert", "true")
    try:
        with urllib.request.urlopen(req) as response:
            response.read()
    except urllib.error.HTTPError as error:
        sys.exit(f"POST {path} failed: {error.code}\n{error.read().decode()}")


# --------------------------------------------------------------------- mixing

def three_way_split(rng: random.Random, pool: list[str]) -> list[tuple[str, float]]:
    """One dominant taste at 60%, the rest sharing 40%.

    The shape matters more than the numbers: a profile whose genres are evenly
    spread has no main thing, and "what are they *into*" is the question the
    card answers.
    """
    picks = rng.sample(pool, rng.choice([2, 3]))
    rest = picks[1:]
    shares = [(picks[0], 0.60)]
    if rest:
        # Split the remaining 40 unevenly, or two-genre people all look alike.
        weights = [rng.uniform(0.6, 1.4) for _ in rest]
        total = sum(weights)
        shares += [(genre, 0.40 * w / total) for genre, w in zip(rest, weights)]
    return shares


def music_records(rng: random.Random, mix, now):
    """Songs in proportion to the mix, as `apple_music` rows."""
    rows, plays = [], 40
    for genre, share in mix:
        for artist in ARTISTS[genre]:
            count = max(1, round(plays * share))
            rows.append({
                "source": "apple_music", "data_type": "song",
                "item_id": f"syn-{genre}-{artist}".replace(" ", "-").lower(),
                "name": f"{artist} — top track", "creator": artist,
                "detail": genre,
                "extra": {"genres": genre, "play_count": str(count)},
                "collected_at": now,
            })
    return rows


def domains(music_mix, sport_sessions: int) -> list[dict]:
    """The ontology mix the dynamic profile draws its three figures from.

    Mirrors `Ontology.mix` in Written/Services/Ontology.swift: count per domain,
    share over *placed* items, sorted by share and then by the domain's raw
    value so the same account always produces the same three bars in the same
    order. Two deliberate departures, both because this is a seeder and not a
    phone:

    * **Music is weighted by plays, not by song count.** `Ontology.mix` counts
      songs, but `music_records` writes one row per artist rather than a real
      library, so a headcount would put every synthetic person at ~90% sport
      against a sessions figure that runs to 90. The play counts it already
      computes in proportion to the mix are the honest analogue.
    * **Calendar events are not placed, and YouTube never is.** Placing an event
      needs `Ontology.classify`, and a second copy of that term table in Python
      is exactly the parallel vocabulary the domain constants above exist to
      avoid. YouTube is absent by construction — `Ontology.mix` takes no such
      parameter, since applying a term list to a channel name is the inference
      III.E.4.h prohibits.

    So the shares here are music against played sport. That is thinner than a
    real distillation and it is honest about being thin: the alternative is
    inventing breadth on a page whose whole subject is what somebody's attention
    is actually made of.
    """
    counts: dict[str, int] = {}
    for genre, share in music_mix:
        for _ in ARTISTS[genre]:
            counts[MUSIC_DOMAIN] = counts.get(MUSIC_DOMAIN, 0) + max(1, round(40 * share))
    if sport_sessions:
        counts[SPORT_DOMAIN] = sport_sessions

    total = sum(counts.values())
    if not total:
        return []
    ranked = sorted(counts.items(), key=lambda kv: (-kv[1] / total, kv[0]))
    return [{"domain": d, "share": round(n / total, 4)} for d, n in ranked]


def top_subjects(music_mix, limit: int = 3) -> list[dict]:
    """The three named things the dynamic profile draws, ranked.

    Mirrors `Ontology.subjects`: Apple Music only, one count per song row,
    shares over the music counted, ties broken on the name so the same account
    always produces the same row. `music_records` writes one row per artist with
    a play count in proportion to the mix, so the play count is the weight here
    for the same reason `domains` uses it — a headcount would make every
    synthetic person's three figures identical.

    No classical exception, because the seeded rows carry no `composer`: Apple
    Music supplies one for a minority of real classical tracks (42 of 481 on the
    library this was measured against) and inventing one here would make the
    seeded data better than anything a real account can produce.
    """
    counts: dict[str, int] = {}
    for genre, share in music_mix:
        for artist in ARTISTS[genre]:
            counts[artist] = counts.get(artist, 0) + max(1, round(40 * share))

    total = sum(counts.values())
    if not total:
        return []
    ranked = sorted(counts.items(), key=lambda kv: (-kv[1] / total, kv[0]))
    return [{"subject": s, "share": round(n / total, 4)} for s, n in ranked[:limit]]


def video_records(rng: random.Random, mix, now):
    rows = []
    for category, share in mix:
        for channel in CHANNELS[category]:
            rows.append({
                "source": "youtube", "data_type": "subscription",
                "item_id": f"syn-{category}-{channel}".replace(" ", "-").lower(),
                "name": channel, "creator": channel, "detail": category,
                "extra": {"category": category, "share": f"{share:.2f}"},
                "collected_at": now,
            })
    return rows


# ------------------------------------------------------------------- photos

# Portrait, at the ratio the grid draws. Small on purpose: these compress to a
# couple of kilobytes each and there are six per person, so the whole seed adds
# well under a megabyte to a bucket whose ceiling is 15 MB per object.
PHOTO_WIDTH, PHOTO_HEIGHT = 600, 800


def gradient_png(top: tuple[int, int, int], bottom: tuple[int, int, int]) -> bytes:
    """A vertical two-tone gradient, written with nothing but the standard library.

    **Deliberately not a face.** Generated portraits were removed from this app
    once already — `photo_seeds` drove them and made every real account look
    photographed when none of them were — so these read as placeholders at a
    glance and cannot be mistaken for a person. What they have to prove is that
    the pipeline works end to end: an object in a private bucket, a `photos`
    row pointing at it, a path on the discovery card, and a signed URL the app
    can actually fetch. A coloured rectangle proves all four.

    PNG rather than JPEG so this needs no Pillow — a stdlib-only tool is one
    fewer thing to install before somebody can reseed. `0015` allows
    image/jpeg, image/png and image/heic, so PNG is a first-class choice here
    rather than a workaround.

    The gradient runs vertically, so every scanline is one colour repeated and
    the whole image is built a row at a time instead of a pixel at a time —
    600x800 is 480,000 pixels and per-pixel Python would make seeding six
    accounts noticeably slow for no visible gain.
    """
    raw = bytearray()
    for y in range(PHOTO_HEIGHT):
        t = y / (PHOTO_HEIGHT - 1)
        colour = bytes(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        raw.append(0)                       # filter type 0 (none) for this row
        raw += colour * PHOTO_WIDTH

    def chunk(tag: bytes, data: bytes) -> bytes:
        body = tag + data
        return (struct.pack(">I", len(data)) + body
                + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", PHOTO_WIDTH, PHOTO_HEIGHT,
                                         8, 2, 0, 0, 0))    # 8-bit truecolour
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def photo_palette(index: int, position: int) -> tuple[tuple[int, int, int], tuple[int, int, int]]:
    """Six distinguishable tiles per person, and a different set per person.

    The six have to differ from each other or the feed's rotation — two
    photographs per appearance, drawn without replacement — looks broken rather
    than varied. Hue walks by a large step per slot so neighbours never land
    close together.
    """
    hue = (index * 61 + position * 47) % 360

    def rgb(h: int, value: float) -> tuple[int, int, int]:
        # Small HSV-to-RGB at fixed saturation; enough for a placeholder and it
        # keeps this file free of colorsys imports for one call site.
        c = value * 0.55
        x = c * (1 - abs((h / 60.0) % 2 - 1))
        m = value - c
        r, g, b = [(c, x, 0), (x, c, 0), (0, c, x),
                   (0, x, c), (x, 0, c), (c, 0, x)][int(h / 60) % 6]
        return (round((r + m) * 255), round((g + m) * 255), round((b + m) * 255))

    return rgb(hue, 0.85), rgb((hue + 24) % 360, 0.45)


def upload_photos(key: str, uid: str, index: int) -> list[str]:
    """Six objects in the bucket, six `photos` rows, and the paths for the card.

    All three, because each is read by something different and any one of them
    missing is silent. The object alone is invisible: `PhotoService.paths()`
    lists `public.photos`, not the bucket. The row alone points at nothing and
    draws a broken picture. And `discovery_cards.photo_paths` is what both the
    feed and `MatchProfileService` read, so a card without it shows a person
    with no face however well the other two landed.

    Paths follow `<user_id>/<position>.<ext>`, which is not cosmetic: `0015`'s
    insert policy checks `auth.uid()::text = (storage.foldername(name))[1]`, so
    the first path component *is* the authorisation.
    """
    paths = []
    for position in range(6):
        path = f"{uid}/{position}.png"
        top, bottom = photo_palette(index, position)
        upload(f"/storage/v1/object/profile-photos/{path}",
               key, gradient_png(top, bottom), "image/png")
        request("POST", "/rest/v1/photos", key, {
            "user_id": uid, "position": position,
            "object_path": path, "kind": "photo",
        }, {"Prefer": "resolution=merge-duplicates"})
        paths.append(path)
    return paths


def user_records(index: int, now):
    """The school and the bio, in the shape `setUserFact` writes them.

    Source `user`, the data type doubling as the item id, the value in `name`,
    and `entered_by_user=1` in `extra` — matched field for field against
    DistillViewModel, because `0037` selects the latest row per data type for
    exactly `education` and `bio` and anything shaped differently is invisible
    to it. These are also what `IdentitySummary` reads for the dashboard, so a
    seeded account's own Memories tab reads the same as its match profile.
    """
    school, bio = BIOGRAPHICS[index]
    return [
        {
            "source": "user", "data_type": data_type, "item_id": data_type,
            "name": value, "creator": "", "detail": "",
            "extra": {"entered_by_user": "1"},
            "collected_at": now,
        }
        for data_type, value in (("education", school), ("bio", bio))
    ]


def calendar_records(index: int, now):
    rows = []
    for title, organizer in CALENDAR_PLAN[index]:
        rows.append({
            "source": "apple_calendar", "data_type": "event",
            "item_id": f"syn-event-{index}-{title}".replace(" ", "-").lower(),
            "name": title, "creator": organizer or "", "detail": "",
            # `booked=1` is what tells a ticketed event from a typed one — the
            # same flag CalendarDistiller writes. See CLAUDE.md.
            "extra": {"booked": "1"} if organizer else {},
            "collected_at": now,
        })
    return rows


def interests(music_mix, video_mix) -> list[dict]:
    """What the card draws its two lines from.

    Subjects only. An artist and a channel are things a line can be *about*;
    the songs and videos they came from stay in `distilled_records` behind the
    policy that has always guarded them.
    """
    out = []
    for genre, _ in music_mix:
        out += [{"domain": MUSIC_DOMAIN, "subject": a} for a in ARTISTS[genre]]
    for category, _ in video_mix:
        out += [{"domain": VIDEO_DOMAINS[category], "subject": c}
                for c in CHANNELS[category]]
    return out


# ----------------------------------------------------------------------- main

def discard_photos(key: str, uid: str) -> None:
    """Remove one account's six objects, tolerating their absence.

    **The one place in this file where an HTTP error is not fatal**, and the
    exception is argued rather than convenient: `request` calls `sys.exit` on
    any error because a refused write during seeding leaves a half-built
    account that looks real, and stopping is the honest response. Here the
    opposite holds — accounts seeded before photographs existed have nothing at
    these paths, and refusing to wipe them because a file is already gone would
    make `--wipe` fail exactly when it is most needed. A missing object is the
    desired end state arriving early.
    """
    body = json.dumps({
        "prefixes": [f"{uid}/{position}.png" for position in range(6)],
    }).encode()
    req = urllib.request.Request(f"{BASE}/storage/v1/object/profile-photos",
                                 data=body, method="DELETE")
    req.add_header("apikey", key)
    req.add_header("Authorization", f"Bearer {key}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as response:
            response.read()
    except urllib.error.HTTPError as error:
        print(f"  (photographs for {uid[:8]}… not removed: {error.code})")


def wipe(key: str) -> None:
    users = request("GET", "/auth/v1/admin/users?per_page=200", key) or {}
    removed = 0
    for user in users.get("users", []):
        if user.get("email", "").endswith(SYNTHETIC_DOMAIN):
            # **Storage first, while the id still means something.** Deleting the
            # auth user cascades through every table that references it and
            # leaves the bucket alone — objects are not rows. Do it afterwards
            # and the paths are still derivable, but nothing in the database
            # remembers which ids were ours, so a later cleanup would have
            # nothing to go on.
            discard_photos(key, user["id"])
            request("DELETE", f"/auth/v1/admin/users/{user['id']}", key)
            removed += 1
    print(f"removed {removed} synthetic account(s), photographs included")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--wipe", action="store_true",
                        help="delete the synthetic accounts first")
    parser.add_argument("--seed", type=int, default=7,
                        help="so a rerun produces the same six people")
    args = parser.parse_args()

    key = env_key()
    if args.wipe:
        wipe(key)

    rng = random.Random(args.seed)
    now = datetime.now(timezone.utc).isoformat()

    for index, name in enumerate(PEOPLE):
        email = f"synthetic-{index + 1}@{SYNTHETIC_DOMAIN}"
        created = request("POST", "/auth/v1/admin/users", key, {
            "email": email,
            "password": f"syn-{rng.getrandbits(48):x}",
            "email_confirm": True,
        })
        uid = created["id"]

        age = rng.randint(20, 28)
        district = rng.choice(DISTRICTS)
        music_mix = three_way_split(rng, MUSIC_GENRES)
        video_mix = three_way_split(rng, VIDEO_CATEGORIES)

        request("POST", "/rest/v1/users", key, {
            "id": uid, "first_name": name,
            "birth_year": datetime.now().year - age,
            "sex": GENDERS[index],
            "place": district,
            "tree_seed": rng.getrandbits(62),
        }, {"Prefer": "resolution=merge-duplicates"})

        rows = (music_records(rng, music_mix, now)
                + video_records(rng, video_mix, now)
                + calendar_records(index, now)
                + user_records(index, now))
        request("POST", "/rest/v1/distilled_records", key,
                [dict(r, user_id=uid) for r in rows],
                {"Prefer": "resolution=merge-duplicates"})

        for source in ("apple_music", "youtube", "apple_calendar", "health"):
            request("POST", "/rest/v1/source_connections", key, {
                "user_id": uid, "source": source,
                "last_distilled_at": now,
                "record_count": sum(1 for r in rows if r["source"] == source),
            }, {"Prefer": "resolution=merge-duplicates"})

        label, wake = rng.choice(CHRONOTYPES)
        request("POST", "/rest/v1/health_signals", key, {
            "user_id": uid, "chronotype_label": label,
            "median_wake_minutes": wake + rng.randint(-20, 20),
            "spread_minutes": rng.randint(15, 70),
            "days_observed": rng.randint(60, 340),
            "average_daily_steps": rng.randint(3200, 13500),
            "hourly_activity": [round(rng.uniform(0, 1), 3) for _ in range(24)],
        }, {"Prefer": "resolution=merge-duplicates"})

        sport = rng.choice(SPORTS)
        # Held in a variable rather than inlined, because the same number is the
        # `playedSport` weight on the card below — the row and the share have to
        # agree or the profile contradicts the dashboard.
        sessions = rng.randint(4, 90) if sport else 0
        if sport:
            request("POST", "/rest/v1/health_sports", key, {
                "user_id": uid, "sport": sport,
                "sessions": sessions,
                "minutes": rng.randint(120, 4200),
            }, {"Prefer": "resolution=merge-duplicates"})

        photo_paths = upload_photos(key, uid, index)

        request("POST", "/rest/v1/discovery_cards", key, {
            "user_id": uid, "display_name": name, "age": age,
            "district": district,
            "photo_paths": photo_paths,
            "photo_seeds": [rng.randint(1, 10**6) for _ in range(6)],
            "interests": interests(music_mix, video_mix),
            "domains": domains(music_mix, sessions),
            "top_subjects": top_subjects(music_mix),
        }, {"Prefer": "resolution=merge-duplicates"})

        main_genre = music_mix[0][0]
        print(f"  {name:8s} {age}  {district:24s} {main_genre} + "
              f"{len(music_mix) - 1} more, {sport or 'no sport'}")

    print(f"\nseeded {len(PEOPLE)} synthetic accounts")


if __name__ == "__main__":
    main()
