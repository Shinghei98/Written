"""Turning encrypted vault rows into semantic evidence.

**This is the other half of the split the whole design rests on.** The ingestion
identity holds `GenerateDataKey` and `Encrypt` and cannot read a row back; this
one holds `Decrypt` and cannot write one. Neither alone can both put data in the
vault and take it out, which is what makes the vault worth having.

What it does not do is as important as what it does. It projects **music only**.
Calendar and HealthKit rows are captured, encrypted and deliberately left
unprojected: `private_observation_projection_is_valid_v03` returns `true`
immediately for every other source but imposes a strict sanitised shape on those
two — `calendar-v03`, `sanitized_classification`, `action_weight = 0`, a payload
under 1 KB with a `classification_state`. That shape is the *output of a
classifier* this file does not implement, and §7 is explicit that only the
current Calendar classifier may run over Calendar rows. Writing something that
merely satisfies the constraint would be inventing evidence.
"""

from __future__ import annotations

import base64
import json
from typing import Any

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

# Sources this file is willing to project. Everything else is captured and left
# alone until its own classifier exists.
PROJECTABLE = {"apple_music", "music_library", "spotify"}

PAYLOAD_SCHEMA_VERSION = "music-v03"
OBSERVATION_KIND = "catalog_item"
PRIVACY_CLASS = "public_catalog"

# One batch per invocation. A Lambda has fifteen minutes and a library has
# thousands of rows; a cap that leaves work behind is better than an invocation
# that dies half way and leaves the job's state ambiguous — the queue will hand
# the rest back on the next tick.
MAX_RECORDS_PER_RUN = 400


def decrypt_payload(dek: bytes, ciphertext: bytes) -> dict[str, Any]:
    """`iv || ciphertext || tag`, as `aws/ingestion/lib.mjs` writes it."""
    return json.loads(AESGCM(dek).decrypt(ciphertext[:12], ciphertext[12:], None))


def normalize(envelope: dict[str, Any]) -> dict[str, Any] | None:
    """The evidence a music row carries, with the capture stripped out.

    **Deliberately not the whole envelope.** `observed_at`, `ingestion_id` and
    the transport fields describe *how* the row was collected; an observation is
    about what was observed. The raw envelope stays in the vault for anything
    that later wants it.

    Handles both payload wire forms. v1 put an enum's associated value under
    Swift's synthesised `_0`; v2 writes `{"kind": …, "value": …}`. **v1 rows
    exist forever** — the ingestion identity has no `Decrypt`, so nothing can
    ever re-encode them — which is what `schema_version` is for.
    """
    payload = envelope.get("typed_payload") or {}
    if "kind" in payload and "value" in payload:          # v2
        kind, value = payload.get("kind"), payload.get("value") or {}
    elif "music" in payload:                               # v1
        kind, value = "music", (payload["music"] or {}).get("_0") or {}
    else:
        return None
    if kind != "music":
        return None

    fields = {
        "title": value.get("title"),
        "primary_performer": value.get("primaryPerformer"),
        "credited_artists": value.get("creditedArtists") or [],
        "composer": value.get("composer"),
        "album": value.get("album"),
        "genres": value.get("genres") or [],
        "release_date": value.get("releaseDate"),
        "isrc": value.get("isrc"),
        "play_count": value.get("playCount"),
        "rank": value.get("rank"),
    }
    # An absent field and a field the source returned empty are the same thing
    # to a resolver, and carrying both wastes the 1 KB the private sources are
    # held to — a limit worth respecting everywhere rather than only where it
    # is enforced.
    fields = {k: v for k, v in fields.items() if v not in (None, "", [], {})}
    if not fields.get("title"):
        return None

    fields["schema_version"] = PAYLOAD_SCHEMA_VERSION
    fields["record_kind"] = "music_item"
    return fields


SELECT_PENDING = """
select r.id, r.ingestion_run_id, r.connector_source_code, r.source_code,
       r.data_type, r.occurred_at, r.source_item_hmac, r.record_fingerprint,
       r.encryption_key_version, r.encrypted_payload,
       i.scope_key,
       coalesce((s.action_weights ->> split_part(i.scope_key, ':', 3))::float8, 0.0)
         as action_weight
  from semantic_private.raw_source_records r
  -- **On the record id alone, and never on the run.** A run item says "this
  -- run saw this item"; the raw record says "this run first captured it". They
  -- are usually different runs — the first Apple Music distillation stored
  -- 1,225 rows and every later one re-affirmed them as duplicates, keeping the
  -- original `ingestion_run_id` on the record while writing items under its
  -- own. Joining on the run matched exactly nothing, and returned zero rows
  -- rather than an error.
  join semantic_private.ingestion_run_items i
    on i.raw_source_record_id = r.id
   and i.user_id = r.user_id
  join semantic_private.sources s on s.source_code = r.source_code
  left join semantic_private.observations o
    on o.user_id = r.user_id
   and o.source_code = r.source_code
   and o.record_fingerprint = r.record_fingerprint
 where r.user_id = %(user_id)s
   and r.lifecycle_state = 'active'
   and r.source_code = any(%(sources)s)
   and o.id is null
 order by r.created_at
 limit %(limit)s
"""

INSERT_OBSERVATION = """
insert into semantic_private.observations (
  user_id, ingestion_run_id, connector_source_code, source_code, data_type,
  observation_kind, action_type, occurred_at,
  source_item_hmac, record_fingerprint,
  payload_schema_version, normalized_payload,
  field_quality, action_weight, privacy_class,
  allow_external_resolution, lifecycle_state, provenance_tier
) values (
  %(user_id)s, %(ingestion_run_id)s, %(connector_source_code)s, %(source_code)s,
  %(data_type)s, %(observation_kind)s, %(action_type)s, %(occurred_at)s,
  %(source_item_hmac)s, %(record_fingerprint)s,
  %(payload_schema_version)s, %(normalized_payload)s,
  1.0, %(action_weight)s, %(privacy_class)s,
  false, 'active', 'typed'
)
on conflict (user_id, source_code, record_fingerprint) do nothing
"""


def project_user(connection, kms, user_id: str, *, vault_key_arn: str) -> dict[str, Any]:
    """Read what this user has in the vault and write the evidence it supports.

    **Idempotent by the same key the vault uses.** `observations` is unique on
    `(user_id, source_code, record_fingerprint)`, exactly as `raw_source_records`
    is, so one row yields one observation however many times this runs — and the
    query only looks at records that have none yet, so a re-run does no work
    rather than doing work and discarding it.
    """
    counts = {"read": 0, "written": 0, "skipped_no_payload": 0, "keys_unwrapped": 0}
    unwrapped: dict[str, bytes] = {}

    with connection.cursor() as cursor:
        cursor.execute(SELECT_PENDING, {
            "user_id": user_id,
            "sources": sorted(PROJECTABLE),
            "limit": MAX_RECORDS_PER_RUN,
        })
        pending = cursor.fetchall()

    for row in pending:
        counts["read"] += 1
        version = row["encryption_key_version"]

        if version not in unwrapped:
            with connection.cursor() as cursor:
                cursor.execute(
                    "select wrapped_dek from semantic_private.user_encryption_keys"
                    " where user_id = %(user_id)s and key_version = %(version)s",
                    {"user_id": user_id, "version": version},
                )
                key_row = cursor.fetchone()
            if key_row is None:
                # A row naming a key that is not there is unreadable forever.
                # That is what crypto-erasure looks like from this side, so it
                # is counted and stepped over rather than raised.
                counts["skipped_no_payload"] += 1
                continue
            # **The encryption context is not optional.** It binds the wrapped
            # key to one user; without it a blob lifted from another row would
            # unwrap happily.
            unwrapped[version] = kms.decrypt(
                CiphertextBlob=bytes(key_row["wrapped_dek"]),
                KeyId=vault_key_arn,
                EncryptionContext={"user_id": user_id},
            )["Plaintext"]
            counts["keys_unwrapped"] += 1

        envelope = decrypt_payload(unwrapped[version], bytes(row["encrypted_payload"]))
        fields = normalize(envelope)
        if fields is None:
            counts["skipped_no_payload"] += 1
            continue

        with connection.cursor() as cursor:
            cursor.execute(INSERT_OBSERVATION, {
                "user_id": user_id,
                "ingestion_run_id": row["ingestion_run_id"],
                "connector_source_code": row["connector_source_code"],
                "source_code": row["source_code"],
                "data_type": row["data_type"],
                "observation_kind": OBSERVATION_KIND,
                # The scope key is `source:data_type:action`, and the action is
                # what the server weighs. Taken from the scope rather than
                # re-derived, so the observation and the head it belongs under
                # cannot disagree.
                "action_type": row["scope_key"].split(":")[2],
                "occurred_at": row["occurred_at"],
                "source_item_hmac": row["source_item_hmac"],
                "record_fingerprint": row["record_fingerprint"],
                "payload_schema_version": PAYLOAD_SCHEMA_VERSION,
                "normalized_payload": json.dumps(fields),
                "action_weight": row["action_weight"],
                "privacy_class": PRIVACY_CLASS,
            })
            counts["written"] += cursor.rowcount

    connection.commit()
    # Nothing here goes near a log: `counts` is integers, and the one place a
    # decrypted title could escape is an exception string, which is why the
    # worker's own boundary records a stable code rather than the error.
    for key in list(unwrapped):
        unwrapped[key] = b"\0" * len(unwrapped[key])
    return counts
