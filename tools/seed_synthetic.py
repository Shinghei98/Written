#!/usr/bin/env python3
"""Seed six synthetic accounts — full datasets, not six cards.

The discovery feed needs people to discover, and there is exactly one real
account. This writes six complete ones: auth user, profile, connections, music
and video records, health signals and calendar events, and finally the
`discovery_cards` row derived from all of it — so a synthetic person is built
the same way a real one is rather than being a card with nothing behind it.

    SUPABASE_SERVICE_ROLE_KEY=... python3 tools/seed_synthetic.py
    SUPABASE_SERVICE_ROLE_KEY=... python3 tools/seed_synthetic.py --wipe

**The service-role key must never reach the app or this repo.** It bypasses row
level security completely, and RLS is the whole authorisation layer here — a
copy of that key is a copy of every account. It is read from the environment,
has no default, and is never printed. Run this from a shell, not from the app,
and not from anything that logs its environment.

`--wipe` deletes the six synthetic auth users first, which cascades every table.
It matches on the seeded email domain and will not touch a real account.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

PROJECT_REF = "fwnezkbesjoazlpaflbq"
BASE = f"https://{PROJECT_REF}.supabase.co"

# Every synthetic account carries this domain, which is what makes `--wipe`
# safe: a real account can never match it.
SYNTHETIC_DOMAIN = "synthetic.written.invalid"

PEOPLE = ["Mina", "Joon", "Elise", "Tobias", "Priya", "Marcus"]

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
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "").strip()
    if not key:
        sys.exit(
            "SUPABASE_SERVICE_ROLE_KEY is not set.\n\n"
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

def wipe(key: str) -> None:
    users = request("GET", "/auth/v1/admin/users?per_page=200", key) or {}
    removed = 0
    for user in users.get("users", []):
        if user.get("email", "").endswith(SYNTHETIC_DOMAIN):
            request("DELETE", f"/auth/v1/admin/users/{user['id']}", key)
            removed += 1
    print(f"removed {removed} synthetic account(s)")


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
            "sex": rng.choice(["female", "male", "other"]),
            "place": district,
            "tree_seed": rng.getrandbits(62),
        }, {"Prefer": "resolution=merge-duplicates"})

        rows = (music_records(rng, music_mix, now)
                + video_records(rng, video_mix, now)
                + calendar_records(index, now))
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
        if sport:
            request("POST", "/rest/v1/health_sports", key, {
                "user_id": uid, "sport": sport,
                "sessions": rng.randint(4, 90),
                "minutes": rng.randint(120, 4200),
            }, {"Prefer": "resolution=merge-duplicates"})

        request("POST", "/rest/v1/discovery_cards", key, {
            "user_id": uid, "display_name": name, "age": age,
            "district": district,
            "photo_seeds": [rng.randint(1, 10**6) for _ in range(6)],
            "interests": interests(music_mix, video_mix),
        }, {"Prefer": "resolution=merge-duplicates"})

        main_genre = music_mix[0][0]
        print(f"  {name:8s} {age}  {district:24s} {main_genre} + "
              f"{len(music_mix) - 1} more, {sport or 'no sport'}")

    print(f"\nseeded {len(PEOPLE)} synthetic accounts")


if __name__ == "__main__":
    main()
