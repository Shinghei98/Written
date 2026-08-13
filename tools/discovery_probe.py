#!/usr/bin/env python3
"""§10's acceptance gate: what one signed-in account can reach about another.

    DEMO_PHONE=+1XXXXXXXXXX DEMO_OTP=XXXXXX \\
        python3 tools/discovery_probe.py <other-user-uuid>

**It signs in as a real user and holds a real token, which is the whole point.**
Every other tool here uses `SUPABASE_SECRET_KEY`, which bypasses row level
security entirely — so a probe built that way would prove nothing about what a
client can reach. `api.discover_profiles`, `api.list_assertions` and
`match_card` are granted to `authenticated` and to nobody else, so only a
genuine session exercises them at all.

The demo account is reachable because it signs in with a fixed test OTP
(`SMS_TEST_OTP`), which is why it exists. **Neither value is in this repo and
neither should be pasted anywhere** — they live in App Store Connect and in your
shell for the length of one run. The anon key below is public by intent: it
ships in the binary and PKCE is what secures the flow.

**Adversarial means it tries to over-reach**, not that it checks the happy path.
Every case below is something a client should be refused, and each prints what
it expected beside what happened — a probe that only said "ok" would be the
defect this codebase keeps finding, where a result nobody reads stands in for a
result nobody checked.

**A refusal is the pass.** Read the column, not the absence of a crash.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

BASE = "https://fwnezkbesjoazlpaflbq.supabase.co"
ANON = "sb_publishable_rKIU-q6beAiLawLkjEiMYA_vZNmC2aT"

PASS = "PASS"
FAIL = "FAIL"

results: list[tuple[str, str, str]] = []


def call(method: str, path: str, token: str, body=None, headers=None):
    """Returns (status, parsed-or-text). Never raises for an HTTP error —
    a refusal is data here rather than an exception."""
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(f"{BASE}{path}", data=data, method=method)
    request.add_header("apikey", ANON)
    request.add_header("Authorization", f"Bearer {token}")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    for key, value in (headers or {}).items():
        request.add_header(key, value)
    try:
        with urllib.request.urlopen(request) as response:
            raw = response.read().decode()
            try:
                return response.status, json.loads(raw)
            except json.JSONDecodeError:
                return response.status, raw
    except urllib.error.HTTPError as error:
        raw = error.read().decode()
        try:
            return error.code, json.loads(raw)
        except json.JSONDecodeError:
            return error.code, raw
    except urllib.error.URLError as error:
        return 0, str(error)


def sign_in() -> str:
    phone = os.environ.get("DEMO_PHONE", "").strip()
    otp = os.environ.get("DEMO_OTP", "").strip()
    if not phone or not otp:
        sys.exit(
            "DEMO_PHONE and DEMO_OTP are not set.\n\n"
            "They are the demo account's test number and its fixed OTP, which "
            "live in App Store Connect. Put them in your shell for this run and "
            "nowhere else."
        )

    # Supabase's test numbers skip Twilio entirely, so this sends no SMS and
    # costs nothing — the reason the demo account is built this way.
    status, body = call("POST", "/auth/v1/otp", ANON, {"phone": phone})
    if status >= 400:
        sys.exit(f"could not request an OTP: {status} {body}")

    status, body = call(
        "POST", "/auth/v1/verify", ANON,
        {"phone": phone, "token": otp, "type": "sms"},
    )
    if status >= 400 or not isinstance(body, dict) or "access_token" not in body:
        sys.exit(f"could not verify the OTP: {status} {body}")
    return body["access_token"]


def record(name: str, ok: bool, detail: str) -> None:
    results.append((PASS if ok else FAIL, name, detail))


def probe(token: str, me: str, other: str) -> None:
    # --- The schemas a client must not reach at all -------------------------
    #
    # `semantic_private` has RLS on with no policy and grants nobody usage;
    # `ontology` likewise. These are the tables holding everybody's evidence.
    for schema, table in (("semantic_private", "user_assertions"),
                          ("semantic_private", "observations"),
                          ("ontology", "concepts")):
        status, body = call(
            "GET", f"/rest/v1/{table}?select=*&limit=1", token,
            headers={"Accept-Profile": schema},
        )
        record(f"{schema}.{table} unreachable", status >= 400,
               f"HTTP {status}")

    # --- Functions that are internals ---------------------------------------
    #
    # `is_blocked` would answer the one question a blocked person must not be
    # able to ask; `matching_terms` would hand over somebody else's terms.
    for fn, args in (("is_blocked", {"p_a": me, "p_b": other}),
                     ("matching_terms", {"p_subject": other})):
        status, _ = call("POST", f"/rest/v1/rpc/{fn}", token, args)
        record(f"{fn} not callable", status >= 400, f"HTTP {status}")

    # --- Another person's account row ---------------------------------------
    #
    # `0001`'s policy is `auth.uid() = id`, so this must come back empty rather
    # than refused: RLS filters, it does not error.
    status, body = call(
        "GET", f"/rest/v1/users?id=eq.{other}&select=id,phone", token)
    record("another user's row invisible",
           status < 400 and isinstance(body, list) and len(body) == 0,
           f"HTTP {status}, {len(body) if isinstance(body, list) else '?'} rows")

    # --- The gated match profile --------------------------------------------
    #
    # The only like between these two is declined, so both halves must refuse.
    # This is `0122` and `0126` from the other side of the wire.
    for fn in ("match_profile", "match_card"):
        status, body = call("POST", f"/rest/v1/rpc/{fn}", token,
                            {"target": other}, {"Prefer": "return=representation"})
        rows = len(body) if isinstance(body, list) else -1
        record(f"{fn} refuses a declined invitation",
               status < 400 and rows == 0, f"HTTP {status}, {rows} rows")

    # --- Forging ------------------------------------------------------------
    #
    # `0123`'s insert policy is `auth.uid() = blocker_id`, so blocking on
    # somebody else's behalf must be refused outright.
    status, _ = call("POST", "/rest/v1/blocks", token,
                     [{"blocker_id": other, "blocked_id": me}])
    record("cannot block on another user's behalf", status >= 400, f"HTTP {status}")

    # `0009` revokes update and grants back only `status, responded_at` to the
    # recipient, so rewriting who sent a like must fail.
    status, _ = call("PATCH", f"/rest/v1/likes?liker_id=eq.{other}", token,
                     {"liker_id": me})
    record("cannot rewrite a like's sender", status >= 400, f"HTTP {status}")

    # --- The discovery surface ----------------------------------------------
    #
    # The flag is per-user (`feature_flag_overrides`). This account has no
    # override, so the surface must refuse — which is what makes a cohort a
    # cohort rather than a global switch.
    status, body = call("POST", "/rest/v1/rpc/discover_profiles", token,
                        {"p_limit": 5},
                        {"Content-Profile": "api", "Accept-Profile": "api"})
    record("discovery refuses an account outside the cohort",
           status >= 400, f"HTTP {status}")

    # --- What is still open, and should be reported rather than hidden -------
    #
    # `discovery_cards` is world-readable to any signed-in user by `0007`, which
    # is exactly the gap `api.discover_profiles` exists to close and which stays
    # open until the legacy read is retired. Recorded as a finding, not a pass.
    status, body = call(
        "GET", f"/rest/v1/discovery_cards?user_id=eq.{other}&select=display_name",
        token)
    rows = len(body) if isinstance(body, list) else -1
    results.append(("NOTE", "discovery_cards still readable directly",
                    f"HTTP {status}, {rows} row(s) — the legacy path, by design"))

    # --- The owner's own surface, as a positive control ----------------------
    #
    # Without this the run cannot tell "everything is refused because the rules
    # work" from "everything is refused because the token is bad".
    status, body = call("POST", "/rest/v1/rpc/list_assertions", token, {},
                        {"Content-Profile": "api", "Accept-Profile": "api"})
    rows = len(body) if isinstance(body, list) else -1
    record("own assertions readable (control)", status < 400 and rows >= 0,
           f"HTTP {status}, {rows} rows")


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    other = sys.argv[1].strip()

    token = sign_in()
    status, body = call("GET", "/auth/v1/user", token)
    me = body.get("id") if isinstance(body, dict) else None
    if not me:
        sys.exit(f"signed in but could not read the user id: {status} {body}")
    if me == other:
        sys.exit("the target must be the *other* account")

    print(f"signed in as {me}\nprobing against {other}\n")
    probe(token, me, other)

    width = max(len(name) for _, name, _ in results)
    for verdict, name, detail in results:
        print(f"{verdict:5} {name:<{width}}  {detail}")

    failed = sum(1 for verdict, _, _ in results if verdict == FAIL)
    print(f"\n{len(results) - failed} of {len(results)} checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
