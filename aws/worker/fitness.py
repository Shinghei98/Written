"""Running the contract's HealthKit classifier over the vault.

**This is the first thing that reads a source's rows and reaches a conclusion
about them**, rather than transcribing them into observations. `observations.py`
projects music because music evidence *is* the catalogue item; HealthKit has no
such transcription — `private_observation_projection_is_valid_v03` imposes a
sanitised classifier-output shape on it, and the classifier is
`written_ontology.healthkit`, which is vendored, tested and not reimplemented
here.

What this file adds is the join: vault rows are typed envelopes, and
`ingest_healthkit_rows` reads the **legacy** row shape — `source`, `data_type`,
`item_id` and a semicolon `extra` string. `legacy_row` is that adapter and it is
the only interesting code here.

**It writes a coverage snapshot and, today, nothing else.** With no `HKWorkout`
samples the classifier's answer is `aggregate_only` and zero habit candidates,
because every `activity:*` and `routine:*` concept it can nominate is derived
from workouts. That is the contract's §10 requirement — *aggregate-only
HealthKit produces zero fitness claims* — and recording it as a row is what
makes the abstention reviewable rather than merely absent.
"""

from __future__ import annotations

from typing import Any

from written_ontology.healthkit import (
    HEALTHKIT_POLICY_VERSION,
    ingest_healthkit_rows,
)

BUILDER_MODEL_ROLE = "fitness_habit_builder"

# **No cap, unlike `observations.py`, and the difference is not an oversight.**
# That file writes one observation per row and is idempotent per row, so a cap
# leaves work for the next tick and loses nothing. A coverage snapshot is a
# statement about the *whole* set — "366 activity days, 0 workouts" — so a
# capped read would not defer work, it would produce a confident number that is
# wrong. A year of HealthKit is ~400 rows; if that ever stops being true the
# answer is a windowed snapshot with the window recorded, not a limit.

# **Through `current_source_items`, never the raw table directly**, which is
# this codebase's *read through the summary views* rule one layer down.
#
# Nothing supersedes a prior revision in `raw_source_records`: a row whose
# payload changed is captured beside the old one and both stay `active`. Handing
# the classifier both is not merely redundant — `ingest_healthkit_rows`
# quarantines *both* sides of a lineage whose record fingerprints disagree,
# having no trustworthy revision order in the legacy row shape. So a payload
# change that added one field would take coverage from 390 accepted to zero,
# silently, and read as HealthKit having stopped working.
#
# `current_source_items` is the contract's answer: one row per provider item
# naming its current revision, and a `lifecycle_state` that also drops what the
# provider has since deleted. An item absent from the latest snapshot stops
# feeding the classifier, which is what a tombstone is for.
SELECT_HEALTHKIT = """
select r.id,
       r.data_type,
       r.occurred_at,
       r.encryption_key_version,
       r.encrypted_payload
  from semantic_private.current_source_items i
  join semantic_private.raw_source_records r
    on r.id = i.current_raw_source_record_id
 where i.user_id = %(user_id)s
   and i.source_code = 'healthkit'
   and i.lifecycle_state = 'present'
   and r.lifecycle_state = 'active'
 order by i.occurred_at nulls last, r.id
"""

# **Read at classification time, not at capture time.** A row in the vault was
# admitted under a grant that existed then; this asks whether it exists now.
# Consent that cannot be withdrawn between capture and use is not consent.
SELECT_GRANT = """
select 1
  from semantic_private.healthkit_use_grants
 where user_id = %(user_id)s
   and data_use_purpose = 'fitness_connection'
   and grant_state = 'active'
"""

INSERT_SNAPSHOT = """
insert into semantic_private.fitness_feature_snapshots (
    user_id, input_revision, builder_model_id, policy_version,
    window_end_at, coverage_state,
    accepted_record_count, rejected_record_count,
    activity_day_count, activity_hour_count,
    workout_count, sleep_session_count,
    feature_payload, state, finalized_at
) values (
    %(user_id)s, %(input_revision)s, %(builder_model_id)s, %(policy_version)s,
    now(), %(coverage_state)s,
    %(accepted)s, %(rejected)s,
    %(activity_days)s, %(activity_hours)s,
    %(workouts)s, %(sleep_sessions)s,
    '{}'::jsonb, 'ready', now()
)
-- **`do nothing`, never `do update`.** `on conflict do update` demands update
-- privilege on every column named whether or not a row exists — this project's
-- 42501 lesson — and `0063` deliberately grants the worker insert without it.
-- Re-running the builder against an unchanged revision must cost nothing, which
-- is exactly what this is.
on conflict (user_id, input_revision, builder_model_id, policy_version)
  do nothing
returning id
"""


def _extra(pairs: list[tuple[str, Any]]) -> str:
    """The semicolon `key=value` string the classifier parses.

    Absent values are omitted rather than written empty: `_parse_activity_day`
    counts how many fields it recovered and rejects a row carrying only a date,
    so `steps=` would read as a stated blank rather than an absence.
    """
    return ";".join(f"{key}={value}" for key, value in pairs if value is not None)


def legacy_row(record: dict[str, Any], envelope: dict[str, Any]) -> dict[str, str]:
    """A typed envelope in the shape `ingest_healthkit_rows` reads.

    **The classifier is not adapted to the envelope; the envelope is adapted to
    the classifier.** It is the contract's own code with its own tests, and its
    closed `_ACTIVITY_TYPES` table and its refusal to let free-text workout names
    nominate an activity are the properties worth keeping. Rewriting it to take
    typed input would mean the thing running in production was not the thing the
    tests cover — the same argument as vendoring the queue.
    """
    # **The envelope's own keys are snake_case and the payload's are not.**
    # `SourceEnvelope` carries explicit `CodingKeys`; `FitnessPayload` carries
    # none, so Swift synthesises the property names verbatim — `firstMoveHour`,
    # not `first_move_hour`. Guessing one casing for both reads every field as
    # absent, which here means a snapshot confidently reporting that a full year
    # of activity was malformed.
    payload = (envelope.get("typed_payload") or {}).get("value") or {}
    kind = payload.get("kind") or record["data_type"]
    item_id = envelope.get("provider_item_id") or ""

    if kind == "activity_day":
        first_move = payload.get("firstMoveHour")
        pairs = [
            ("date", payload.get("date")),
            ("steps", _whole(payload.get("steps"))),
            ("active_kcal", _whole(payload.get("activeKcal"))),
            ("exercise_min", _whole(payload.get("exerciseMinutes"))),
            # Back to `HH:00`, which is the shape the classifier matches and the
            # shape the distiller wrote. `%02d:00` only ever emits whole hours,
            # so the round trip through an integer is lossless.
            ("first_move", None if first_move is None else f"{int(first_move):02d}:00"),
        ]
    elif kind == "activity_hour":
        pairs = [
            ("hour", payload.get("hourOfDay")),
            ("steps", _whole(payload.get("steps"))),
            ("share", payload.get("hourShare")),
        ]
    elif kind == "workout":
        pairs = [
            # **`activity_type`, and the sport goes here rather than in `name`.**
            # `_parse_workout` reads only `extra`, and its comment says why —
            # *free-text workout names never nominate an activity*. That guard is
            # against a title somebody typed, and this is not one:
            # `HealthKitDistiller.name(for:)` is a closed mapping off
            # `HKWorkoutActivityType`, an integer enum, so what arrives is a
            # provider activity identifier, which is precisely what the
            # classifier's own closed `_ACTIVITY_TYPES` table is for. Anything
            # outside that table still nominates nothing.
            ("activity_type", payload.get("sport")),
            # `start`, not `started_at`. The app's `extra` key and the
            # classifier's are different words for the same instant, and this is
            # the one line that knows both.
            ("start", _iso(payload.get("startedAt"))),
            ("duration_min", _whole(payload.get("durationMinutes"))),
            ("energy_kcal", _whole(payload.get("energyKcal"))),
            ("distance_km", payload.get("distanceKm")),
        ]
    else:
        pairs = []

    return {
        "source": "healthkit",
        "data_type": kind,
        # The sport for a workout, the day for an activity day — which is what
        # `_parse_workout` reads as the provider activity name and what
        # `_parse_activity_day` falls back to for its date.
        "name": payload.get("sport") or payload.get("date") or item_id,
        "creator": payload.get("recordingApp") or "",
        "item_id": item_id,
        "extra": _extra(pairs),
    }


def _whole(value: Any) -> Any:
    """Integers back as integers.

    The envelope types these as doubles and JSON round-trips them as `8134.0`;
    `_finite_number(..., integer=True)` refuses anything that is not integral in
    the string it is handed. A step count that arrived as a float was silently
    dropped and the day rejected with it.
    """
    if value is None:
        return None
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return value


def _iso(value: Any) -> Any:
    return value if value is None else str(value)


def build_fitness_snapshot(
    connection, kms, user_id: str, *, vault_key_arn: str
) -> dict[str, Any]:
    """Classify this user's HealthKit rows and record what was found.

    Returns counts only. **Nothing this function learns may reach the queue** —
    `worker_job_result_is_safe_v03` allows sixteen keys drawn from a fixed set of
    count and status names, which is §12's no-plaintext rule enforced by the
    schema rather than by anyone remembering it.
    """
    # **Imported here rather than at the top, so `legacy_row` stays pure.**
    # `observations` pulls in `cryptography`, and the adapter — the only part of
    # this file with a silent failure mode — is a function from two dicts to a
    # dict. Requiring a crypto library to test it would have meant not testing
    # it.
    from observations import decrypt_payload

    counts = {"read": 0, "unreadable": 0, "accepted": 0, "written": 0}

    with connection.cursor() as cursor:
        cursor.execute(SELECT_GRANT, {"user_id": user_id})
        if cursor.fetchone() is None:
            # **Not an error.** Somebody with no active fitness grant is somebody
            # this must not derive from, which is a correct outcome and not a
            # failure to report. Whatever is in the vault stays there.
            counts["no_grant"] = 1
            return counts

    with connection.cursor() as cursor:
        cursor.execute(SELECT_HEALTHKIT, {"user_id": user_id})
        pending = cursor.fetchall()

    unwrapped: dict[str, bytes] = {}
    rows: list[dict[str, str]] = []

    for record in pending:
        counts["read"] += 1
        version = record["encryption_key_version"]

        if version not in unwrapped:
            with connection.cursor() as cursor:
                cursor.execute(
                    "select wrapped_dek from semantic_private.user_encryption_keys"
                    " where user_id = %(user_id)s and key_version = %(version)s",
                    {"user_id": user_id, "version": version},
                )
                key_row = cursor.fetchone()
            if key_row is None:
                # Crypto-erasure from this side: a row naming a key that is gone
                # is unreadable forever. Counted and stepped over.
                counts["unreadable"] += 1
                continue
            unwrapped[version] = kms.decrypt(
                CiphertextBlob=bytes(key_row["wrapped_dek"]),
                KeyId=vault_key_arn,
                EncryptionContext={"user_id": user_id},
            )["Plaintext"]

        envelope = decrypt_payload(unwrapped[version], bytes(record["encrypted_payload"]))
        rows.append(legacy_row(record, envelope))

    result = ingest_healthkit_rows(rows)
    coverage = result.coverage
    counts["accepted"] = coverage.accepted_records

    with connection.cursor() as cursor:
        cursor.execute(
            "select id from ontology.model_versions"
            " where model_role = %(role)s and status = 'active'",
            {"role": BUILDER_MODEL_ROLE},
        )
        builder = cursor.fetchone()
    if builder is None:
        raise RuntimeError("no active fitness_habit_builder model version")

    with connection.cursor() as cursor:
        cursor.execute(
            "select revision from semantic_private.user_state_versions"
            " where user_id = %(user_id)s",
            {"user_id": user_id},
        )
        revision_row = cursor.fetchone()
    revision = revision_row["revision"] if revision_row else 0

    identity = {
        "user_id": user_id,
        "input_revision": revision,
        "builder_model_id": builder["id"],
        "policy_version": HEALTHKIT_POLICY_VERSION,
    }

    with connection.cursor() as cursor:
        cursor.execute(INSERT_SNAPSHOT, {
            **identity,
            "coverage_state": str(coverage.state),
            "accepted": coverage.accepted_records,
            "rejected": coverage.rejected_records,
            "activity_days": coverage.activity_days,
            "activity_hours": coverage.activity_hours,
            "workouts": coverage.workouts,
            "sleep_sessions": coverage.sleep_sessions,
        })
        written = cursor.fetchone()

    counts["written"] = 1 if written else 0
    if written:
        counts["snapshot_id"] = str(written["id"])
    else:
        # `do nothing` returns nothing, so a re-run against an unchanged revision
        # has to read back the snapshot it did not write. This is what the
        # `select` in `0063` is for — without it the job would report no
        # snapshot on every run after the first.
        with connection.cursor() as cursor:
            cursor.execute(
                "select id from semantic_private.fitness_feature_snapshots"
                " where user_id = %(user_id)s"
                "   and input_revision = %(input_revision)s"
                "   and builder_model_id = %(builder_model_id)s"
                "   and policy_version = %(policy_version)s",
                identity,
            )
            existing = cursor.fetchone()
        if existing:
            counts["snapshot_id"] = str(existing["id"])

    # **No habit candidates are written, and that is not a stub.** With zero
    # workouts the classifier nominates nothing, because every concept it can
    # reach — `activity:*`, `routine:*_workouts` — is derived from typed workout
    # sessions. Writing the candidate rows is the next unit and needs data that
    # does not exist on any device here yet.
    counts["candidates"] = 0
    # **`abstained` is a claim about the answer, not about the run.** The
    # contract's own result vocabulary carries it, and a coverage state with no
    # typed sessions in it is exactly the case §10 requires produce zero fitness
    # claims. Recording it means "we looked and declined" is queryable rather
    # than inferable from an absence of rows elsewhere.
    counts["abstained"] = coverage.workouts == 0 and coverage.sleep_sessions == 0
    return counts
