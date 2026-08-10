#!/usr/bin/env python3
"""Mint the Apple client secret Supabase's "Secret Key (for OAuth)" field wants.

**Apple's client secret is not a secret — it is a signed token**, and that is the
whole reason this script exists. Google hands you a string you paste and forget;
Apple gives you a `.p8` private key and expects *you* to sign an ES256 JWT with
it, asserting your Team ID, your Services ID and an expiry. Supabase's dashboard
shows no Team ID or Key ID field, so it cannot build one on your behalf — which
is how you know it wants the finished token rather than the key. The panel's own
warning says the rest: *"Apple OAuth secret keys expire every 6 months."* A `.p8`
never expires; only this does.

    python3 tools/apple_client_secret.py \
        --key ~/Downloads/AuthKey_ABC1234567.p8 \
        --team-id  TEAMID1234 \
        --key-id   ABC1234567 \
        --services-id com.written.datingapp.signin

Paste the token it prints into Supabase → Authentication → Providers → Apple →
**Secret Key (for OAuth)**, and put the printed expiry date in a calendar. When
it lapses, Apple linking and web sign-in stop working with no code change and no
deploy to blame — the failure arrives months after the last thing anybody did.

**No dependencies.** `openssl` does the signing and the DER unpacking is below,
which is a few lines and cheaper than asking anyone to install a crypto library
to run a tool they use twice a year. Same reasoning as `seed_synthetic.py`
writing its own PNGs.

**The key never leaves your machine and is never printed.** It is read by
`openssl` from the path you give and nothing here echoes it — the `.p8`
downloads exactly once from Apple and cannot be re-fetched, so treat it like
`sb_secret_…`: not in the repo, not in a chat, not in a screenshot.
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import time


APPLE_AUDIENCE = "https://appleid.apple.com"

# **Apple's ceiling is six months and it is enforced**, not advisory: a token
# claiming longer is rejected outright at the exchange rather than truncated.
# 180 days sits just inside it and lands on a memorable date.
MAX_LIFETIME = 180 * 24 * 60 * 60


def b64url(raw: bytes) -> str:
    """base64url with the padding stripped, as JWT requires."""
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def der_to_jose(der: bytes) -> bytes:
    """Convert OpenSSL's DER ECDSA signature into the raw r||s a JWT carries.

    **This is the step that makes a hand-rolled ES256 token wrong when it is
    wrong.** OpenSSL emits `SEQUENCE { INTEGER r, INTEGER s }`, which is
    variable length; JOSE wants exactly 64 bytes, r and s each padded to 32.
    Pasting the DER straight in produces a token that looks entirely plausible
    and that Apple refuses with `invalid_client`, which reads as a wrong key.

    DER integers are signed, so a value whose top bit is set carries a leading
    zero byte that has to come off — and a short value has to be padded back
    up. Both directions happen in practice, roughly half the time each.
    """
    if der[0] != 0x30:
        sys.exit("openssl did not return a DER sequence — is the key a P-256 EC key?")

    # Skip the sequence header. Lengths under 128 are a single byte; above that
    # the top bit is set and the low bits say how many length bytes follow.
    index = 2 if der[1] < 0x80 else 3 + (der[1] & 0x7F) - 1

    def read_integer(at: int):
        if der[at] != 0x02:
            sys.exit("malformed DER signature — expected an INTEGER")
        length = der[at + 1]
        value = der[at + 2:at + 2 + length]
        return value.lstrip(b"\x00").rjust(32, b"\x00"), at + 2 + length

    r, index = read_integer(index)
    s, _ = read_integer(index)
    return r + s


def sign(message: bytes, key_path: str) -> bytes:
    """ES256 over `message`, via openssl."""
    try:
        result = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", key_path],
            input=message, capture_output=True, check=True,
        )
    except FileNotFoundError:
        sys.exit("openssl not found on PATH.")
    except subprocess.CalledProcessError as error:
        detail = error.stderr.decode(errors="replace").strip()
        sys.exit("openssl could not sign with that key:\n%s" % detail)
    return der_to_jose(result.stdout)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key", required=True, help="path to AuthKey_XXXXXXXXXX.p8")
    parser.add_argument("--team-id", required=True, help="Apple Developer Team ID")
    parser.add_argument("--key-id", required=True, help="Key ID of the .p8")
    parser.add_argument("--services-id", required=True,
                        help="the Services ID, e.g. com.written.datingapp.signin")
    parser.add_argument("--days", type=int, default=180,
                        help="lifetime in days (Apple's maximum is ~180)")
    args = parser.parse_args()

    key_path = os.path.expanduser(args.key)
    if not os.path.isfile(key_path):
        sys.exit("no such key file: %s" % key_path)

    lifetime = args.days * 24 * 60 * 60
    if lifetime > MAX_LIFETIME:
        sys.exit("Apple refuses a lifetime over ~180 days; asked for %d." % args.days)

    issued = int(time.time())
    expires = issued + lifetime

    header = {"alg": "ES256", "kid": args.key_id}
    payload = {
        # **The Team ID issues it and the Services ID is its subject**, which is
        # the pair people most often swap. The bundle id does not appear here at
        # all: that one belongs in Supabase's Client IDs field, for the native
        # flow, and has nothing to do with this token.
        "iss": args.team_id,
        "iat": issued,
        "exp": expires,
        "aud": APPLE_AUDIENCE,
        "sub": args.services_id,
    }

    signing_input = "%s.%s" % (
        b64url(json.dumps(header, separators=(",", ":")).encode()),
        b64url(json.dumps(payload, separators=(",", ":")).encode()),
    )
    token = "%s.%s" % (signing_input, b64url(sign(signing_input.encode(), key_path)))

    print(token)
    print(file=sys.stderr)
    print("expires %s — regenerate before then, or Apple sign-in and account"
          % time.strftime("%Y-%m-%d %H:%M", time.localtime(expires)), file=sys.stderr)
    print("linking stop working with nothing in the app to explain it.", file=sys.stderr)


if __name__ == "__main__":
    main()
