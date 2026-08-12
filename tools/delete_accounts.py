#!/usr/bin/env python3
"""Delete accounts the way the app is supposed to, and sweep what it left behind.

    export SUPABASE_SECRET_KEY=sb_secret_...

    python3 tools/delete_accounts.py show                  # every account, and its objects
    python3 tools/delete_accounts.py delete <uuid> [...]   # dry run
    python3 tools/delete_accounts.py delete <uuid> --apply
    python3 tools/delete_accounts.py sweep-orphans         # dry run
    python3 tools/delete_accounts.py sweep-orphans --apply

The key bypasses row level security entirely. It lives in your shell for the
length of this run and nowhere else — not in the repo, not in a file, not in the
app. See CLAUDE.md: never commit `sb_secret_…`.

## Why this exists rather than a `delete from auth.users`

**Deleting the row is not deleting the person.** Every table in `public`
cascades from `auth.users`, and Storage has no foreign keys at all — so the app's
own `delete-account` function removed every row about somebody and left their
photographs in the bucket. Measured on 2026-08-12: **22 `profile-photos` folders
for 5 live accounts**, plus 6 orphaned `chat-media` folders. Around 60 objects
belonging to people who had asked to be gone.

`supabase/functions/delete-account/index.ts` does the purge now. This tool is
the same sequence for an operator, plus the one thing the function cannot do:
clear the folders left by deletions that already happened.

## The two buckets are keyed differently

    profile-photos  <user_id>/<position>.<ext>      the folder is the user
    chat-media      <conversation_id>/<uuid>.<ext>  the folder is not

So a person's attachments are unreachable by folder name, and their conversation
ids must be read **before** the auth row goes — `conversations` cascades away
with it. Storage first, auth row last: a failed purge leaves an account that can
be retried, a deleted auth row leaves nothing to retry with.

## Dry run by default, and the confirmation is the account name

Deletion here is irreversible and the ids are indistinguishable by eye. `show`
prints the display name beside each id and `--apply` prints the names it is
about to destroy before it does anything.
"""

import argparse
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


def request(method: str, path: str, key: str, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{BASE}{path}", data=data, method=method)
    req.add_header("apikey", key)
    req.add_header("Authorization", f"Bearer {key}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as response:
            raw = response.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        # The body carries the reason; the status alone never says which
        # constraint or policy refused.
        sys.exit(f"{method} {path} failed: {error.code}\n{error.read().decode()}")


# --------------------------------------------------------------------- storage

def objects_under(key: str, bucket: str, folder: str) -> list[str]:
    """Every object key under one folder, paged.

    Storage's list is capped per call and answers names *relative to the
    prefix*, so the folder is put back on. Paging is not decoration: a chat
    folder holds one object per attachment ever sent in that thread, and
    stopping at the first hundred is the same silent partial deletion this tool
    exists to end.
    """
    keys: list[str] = []
    limit = 100
    offset = 0
    while True:
        page = request(
            "POST", f"/storage/v1/object/list/{bucket}", key,
            {"prefix": f"{folder}/", "limit": limit, "offset": offset},
        ) or []
        if not page:
            return keys
        for entry in page:
            # A folder placeholder has no `id`; neither bucket nests, so there
            # is nothing to recurse into and a null name must not reach delete.
            if entry.get("name") and entry.get("id"):
                keys.append(f"{folder}/{entry['name']}")
        if len(page) < limit:
            return keys
        offset += limit


def folders(key: str, bucket: str) -> list[str]:
    """Top-level folder names in a bucket.

    The listing at the root returns folders as entries with a null `id`, which
    is the same fact `objects_under` uses to *skip* them — read from the other
    end here.
    """
    names: list[str] = []
    limit = 100
    offset = 0
    while True:
        page = request(
            "POST", f"/storage/v1/object/list/{bucket}", key,
            {"prefix": "", "limit": limit, "offset": offset},
        ) or []
        if not page:
            return names
        names.extend(e["name"] for e in page if e.get("name") and not e.get("id"))
        if len(page) < limit:
            return names
        offset += limit


def remove_objects(key: str, bucket: str, keys: list[str]) -> None:
    if not keys:
        return
    request("DELETE", f"/storage/v1/object/{bucket}", key, {"prefixes": keys})


# ---------------------------------------------------------------------- people

def accounts(key: str) -> dict[str, str]:
    """Live account ids to a readable name.

    The name comes from `discovery_cards`, which is what every other surface in
    this project shows, so an operator confirming a deletion sees the same word
    the app does.
    """
    rows = request("GET", "/rest/v1/users?select=id", key) or []
    cards = request("GET", "/rest/v1/discovery_cards?select=user_id,display_name", key) or []
    names = {c["user_id"]: c.get("display_name") or "(no name)" for c in cards}
    return {row["id"]: names.get(row["id"], "(no card)") for row in rows}


def conversations_of(key: str, user_id: str) -> list[str]:
    rows = request(
        "GET",
        f"/rest/v1/conversations?select=id&or=(user_a.eq.{user_id},user_b.eq.{user_id})",
        key,
    ) or []
    return [row["id"] for row in rows]


# ------------------------------------------------------------------- commands

def show(key: str) -> None:
    live = accounts(key)
    photo_folders = set(folders(key, "profile-photos"))
    media_folders = set(folders(key, "chat-media"))
    live_conversations = {
        row["id"] for row in (request("GET", "/rest/v1/conversations?select=id", key) or [])
    }

    print(f"{len(live)} account(s):")
    for user_id, name in sorted(live.items(), key=lambda kv: kv[1]):
        owned = len(objects_under(key, "profile-photos", user_id))
        print(f"  {user_id}  {name:<16} {owned} photo object(s)")

    print(f"\nprofile-photos: {len(photo_folders)} folder(s), "
          f"{len(photo_folders - set(live))} orphaned")
    print(f"chat-media:     {len(media_folders)} folder(s), "
          f"{len(media_folders - live_conversations)} orphaned")


def delete(key: str, ids: list[str], apply: bool) -> None:
    live = accounts(key)
    unknown = [i for i in ids if i not in live]
    if unknown:
        sys.exit("no such account: " + ", ".join(unknown))

    print(("DELETING" if apply else "would delete") + f" {len(ids)} account(s):")
    for user_id in ids:
        print(f"  {live[user_id]}  ({user_id})")

    for user_id in ids:
        media: list[str] = []
        for conversation_id in conversations_of(key, user_id):
            media.extend(objects_under(key, "chat-media", conversation_id))
        photos = objects_under(key, "profile-photos", user_id)
        print(f"\n{live[user_id]}: {len(photos)} photo(s), {len(media)} attachment(s)")

        if not apply:
            continue

        # Same order as the edge function, for the same reason: everything that
        # can fail happens while the account still exists and can be retried.
        remove_objects(key, "chat-media", media)
        remove_objects(key, "profile-photos", photos)
        request("DELETE", f"/auth/v1/admin/users/{user_id}", key)
        print(f"  deleted {live[user_id]}")

    if not apply:
        print("\ndry run — pass --apply to act")


def sweep_orphans(key: str, apply: bool) -> None:
    """Folders belonging to nobody, from deletions that predate the purge.

    **Keyed off what is live, never off a list of who was deleted**, because no
    such list exists — an account that is gone left no record of itself. So the
    test is membership in `auth.users` and `conversations`, which is exactly the
    property that makes an object unreachable by any code path in the app.
    """
    live = set(accounts(key))
    live_conversations = {
        row["id"] for row in (request("GET", "/rest/v1/conversations?select=id", key) or [])
    }

    total = 0
    for bucket, keep in (("profile-photos", live), ("chat-media", live_conversations)):
        orphans = [f for f in folders(key, bucket) if f not in keep]
        for folder in orphans:
            keys = objects_under(key, bucket, folder)
            total += len(keys)
            print(f"  {bucket}/{folder}  {len(keys)} object(s)")
            if apply:
                remove_objects(key, bucket, keys)

    print(f"\n{total} object(s) " + ("removed" if apply else "would be removed"))
    if not apply:
        print("dry run — pass --apply to act")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["show", "delete", "sweep-orphans"])
    parser.add_argument("ids", nargs="*")
    parser.add_argument("--apply", action="store_true",
                        help="actually delete; without it nothing is touched")
    args = parser.parse_args()

    key = env_key()
    if args.command == "show":
        show(key)
    elif args.command == "delete":
        if not args.ids:
            sys.exit("name at least one account id — `show` lists them")
        delete(key, args.ids, args.apply)
    else:
        sweep_orphans(key, args.apply)


if __name__ == "__main__":
    main()
