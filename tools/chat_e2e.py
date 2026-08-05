#!/usr/bin/env python3
"""Drive the *other* side of a conversation, so the chat can be proven end to end.

The chat is built and has never carried a message. It cannot be tested from one
account: row level security makes each half of a conversation invisible to the
other, so somebody has to be the second person. This is that somebody — one of
the six synthetic accounts `seed_synthetic.py` creates, acted out over REST.

You drive the app on a real device (a simulator cannot Sign in with Apple); this
drives the synthetic side and reads the database back. **Read the database after
every step rather than trusting the screen** — a refused write in this app looks
exactly like nothing having happened, because `lastError` is recorded and never
displayed.

    export SUPABASE_SECRET_KEY=sb_secret_...

    python3 tools/chat_e2e.py users              # who exists, and their ids
    python3 tools/chat_e2e.py like   <from> <to> # synthetic likes you
    python3 tools/chat_e2e.py like   <from> <to> "say something"   # …with a note
    python3 tools/chat_e2e.py reply  <from> "…" <to>   # synthetic answers you
                                                 # <to> is required once that
                                                 # account has two threads
    python3 tools/chat_e2e.py state  <a> <b>     # every row about the pair

The key bypasses row level security completely. It lives in your shell for the
length of this run and nowhere else — not in the repo, not in a file, not in the
app. Rotate it when you are done. See CLAUDE.md: never commit `sb_secret_…`.
"""

import json
import os
import sys
import urllib.error
import urllib.request

BASE = "https://fwnezkbesjoazlpaflbq.supabase.co"


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


# ------------------------------------------------------------------- who is who

def users(key):
    """Every account, so the run can name its two parties explicitly.

    Named rather than looped over, deliberately. The key ignores RLS, so a script
    that iterated accounts could write likes from strangers to strangers and
    there is **no delete policy on `likes`** to undo it with.
    """
    payload = request("GET", "/auth/v1/admin/users?per_page=200", key) or {}
    people = payload.get("users", payload if isinstance(payload, list) else [])
    # `first_name`, not `display_name` — the latter lives on `discovery_cards`.
    # This matters beyond naming: `LikeService.like` sends
    # `SupabaseAuth.firstName` as `liker_name`, so using anything else here would
    # make the synthetic admirer's row a shape the app never produces, and the
    # test would be checking a fiction.
    profiles = request("GET", "/rest/v1/users?select=id,first_name", key) or []
    names = {p["id"]: p.get("first_name") for p in profiles}
    cards = request("GET", "/rest/v1/discovery_cards?select=user_id,display_name", key) or []
    shown = {c["user_id"]: c.get("display_name") for c in cards}

    print(f"{'id':<38} {'first_name':<14} {'card':<14} email")
    print("-" * 92)
    for person in sorted(people, key=lambda u: u.get("created_at", "")):
        uid = person.get("id", "")
        print(f"{uid:<38} {str(names.get(uid) or '—'):<14} "
              f"{str(shown.get(uid) or '—'):<14} {person.get('email') or '(apple)'}")
    print(f"\n{len(people)} account(s). Synthetic ones carry a card; yours will not.")


# --------------------------------------------------------------------- actions

def like(key, liker, liked, message=None):
    """A like from the synthetic account to you, shaped as the app shapes one.

    `liker_name` and `liker_photo_seed` are denormalised onto the row because the
    recipient cannot look them up — `public.users` is `auth.uid() = id` and a
    real account has no `discovery_cards` row. If those are wrong here, the
    admirers list is wrong, which is itself worth seeing.

    `message` is the note the compose sheet sends with an invitation, and it is
    optional here for the same reason it is optional there: a plain heart writes
    no note, and the two rows have to be distinguishable to test that the
    admirers list draws them differently and orders written ones first. Needs
    `0018_like_message.sql` applied; without it the column does not exist and
    this fails with a message saying so.
    """
    profile = request("GET", f"/rest/v1/users?id=eq.{liker}&select=first_name", key) or []
    name = (profile[0].get("first_name") if profile else None) or "Someone"
    row = {
        "liker_id": liker,
        "liked_id": liked,
        "liker_name": name,
        "liker_photo_seed": stable_seed(liker),
    }
    # Omitted rather than sent as null when absent, so this row is exactly what
    # a plain heart writes.
    if message:
        row["message"] = message
    request(
        "POST", "/rest/v1/likes", key, [row],
        {"Prefer": "resolution=merge-duplicates,return=minimal"},
    )
    wrote = f' saying "{message}"' if message else " with no note"
    print(f"{name} ({liker[:8]}…) now likes {liked[:8]}…{wrote} — open Chat on the device.")


def stable_seed(user_id: str) -> int:
    """The same fold as `PortraitSeed.stable`, so the face matches the app's.

    djb2 by hand rather than `hash()`, for the reason the Swift side gives:
    Python salts `hash()` per process, so the portrait would change every run.
    """
    accumulated = 5381
    for byte in user_id.encode():
        accumulated = (accumulated * 33 + byte) % (2 ** 64)
    return accumulated % 1000


def reply(key, sender, body, to=None):
    """A message from the synthetic side, into a named thread.

    **`to` matters as soon as an account has been in two conversations**, which
    happens the first time one synthetic is used for a second run. This took
    `rows[0]` and no ordering, so a message meant for you went into an old
    synthetic-to-synthetic thread and reported success — the id in the output was
    the only sign, and only if you knew what it should have been.

    Ambiguity is now an error rather than a guess. The key ignores RLS, so a
    wrong guess writes into somebody else's conversation with nothing to stop it.
    """
    rows = request(
        "GET",
        f"/rest/v1/conversations?or=(user_a.eq.{sender},user_b.eq.{sender})"
        "&select=id,user_a,user_b,last_message",
        key,
    ) or []
    if not rows:
        sys.exit(
            "No conversation for that account yet.\n"
            "Accept the like on the device first — the insert policy on "
            "`conversations` requires an accepted like, and that is one of the "
            "two things this run exists to prove."
        )

    if to:
        rows = [r for r in rows if to in (r["user_a"], r["user_b"])]
        if not rows:
            sys.exit(f"{sender[:8]}… and {to[:8]}… have no conversation.")
    if len(rows) > 1:
        listing = "\n".join(
            f"    {r['id']}  with {(r['user_b'] if r['user_a'] == sender else r['user_a'])}"
            f"   last={r['last_message']!r}"
            for r in rows
        )
        sys.exit(
            f"{sender[:8]}… is in {len(rows)} conversations. Name the other "
            f"party so this cannot go to the wrong one:\n\n"
            f"    reply <from> \"…\" <to>\n\n{listing}"
        )
    thread = rows[0]["id"]
    request("POST", "/rest/v1/messages", key,
            [{"conversation_id": thread, "sender_id": sender, "body": body}])
    print(f"sent into {thread[:8]}… — the device polls every 4s.")


# ----------------------------------------------------------------------- state

def state(key, a, b):
    """Every row about the pair, which is what the screen cannot tell you."""
    likes = request(
        "GET",
        f"/rest/v1/likes?or=(and(liker_id.eq.{a},liked_id.eq.{b}),"
        f"and(liker_id.eq.{b},liked_id.eq.{a}))&select=*",
        key,
    ) or []
    print("likes")
    for row in likes:
        print(f"   {row['liker_id'][:8]}… → {row['liked_id'][:8]}…  "
              f"{row['status']:<9} responded={row.get('responded_at')}")
    if not likes:
        print("   (none)")

    pair = sorted([a.lower(), b.lower()])
    convos = request(
        "GET",
        f"/rest/v1/conversations?user_a=eq.{pair[0]}&user_b=eq.{pair[1]}&select=*",
        key,
    ) or []
    print("\nconversations")
    for row in convos:
        # `last_message` is written only by the `touch_conversation` trigger —
        # nothing in the app touches it — so a value here is the trigger working.
        print(f"   {row['id'][:8]}…  last_message={row.get('last_message')!r}")
        print(f"             last_message_at={row.get('last_message_at')}")
    if not convos:
        print("   (none — the accept step has not produced one)")

    for row in convos:
        msgs = request(
            "GET",
            f"/rest/v1/messages?conversation_id=eq.{row['id']}"
            "&select=sender_id,body,created_at,read_at&order=created_at.asc",
            key,
        ) or []
        print(f"\nmessages in {row['id'][:8]}…  ({len(msgs)})")
        for m in msgs:
            print(f"   {m['sender_id'][:8]}…  {m['created_at'][11:19]}  {m['body'][:56]}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    key = env_key()
    command, args = sys.argv[1], sys.argv[2:]
    if command == "users":
        users(key)
    elif command == "like" and len(args) in (2, 3):
        like(key, args[0], args[1], args[2] if len(args) == 3 else None)
    elif command == "reply" and len(args) in (2, 3):
        reply(key, args[0], args[1], args[2] if len(args) == 3 else None)
    elif command == "state" and len(args) == 2:
        state(key, args[0], args[1])
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
