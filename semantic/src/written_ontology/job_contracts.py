"""Typed, fail-closed contracts for semantic worker job payloads.

This module is deliberately only a validation boundary.  It does not claim,
execute, persist, or retry jobs and it does not provide placeholder handlers.
Production enqueue paths and workers should validate with
``JOB_CONTRACT_REGISTRY`` before dispatch and then load private/source data by
the validated durable identifiers.  Raw evidence never belongs in a queue
payload.

The payload schemas are closed allowlists.  This is important even though the
database queue stores JSON: adding a new field is a contract change that must
be reviewed for privacy, idempotency, and stale-revision behaviour.
"""

from __future__ import annotations

import re
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass, fields
from enum import StrEnum
from types import MappingProxyType
from typing import Any, Generic, TypeAlias, TypeVar
from uuid import UUID

from .healthkit import HEALTHKIT_POLICY_VERSION


MAX_DATABASE_REVISION = (1 << 63) - 1
MAX_DATABASE_INTEGER = (1 << 31) - 1
MIN_TERM_MINING_USERS = 5

_CANONICAL_UUID = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
)
_VERSION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:+-]{0,79}$")
_YOUTUBE_CHANNEL_ID = re.compile(r"^UC[A-Za-z0-9_-]{22}$")

# A closed schema would reject these keys as unknown anyway.  Checking them
# first, recursively, makes the privacy boundary explicit and prevents a
# future nested/optional field from accidentally admitting private evidence.
_FORBIDDEN_EXACT_KEYS = frozenset(
    {
        "raw",
        "raw_blob",
        "raw_blob_ref",
        "raw_calendar",
        "raw_event",
        "raw_observation",
        "raw_payload",
        "raw_text",
        "private_payload",
        "private_text",
        "calendar_text",
        "event_text",
        "event_title",
        "event_description",
        "event_notes",
        "itinerary",
        "itinerary_text",
        "route",
        "route_text",
        "ticket",
        "ticket_text",
        "booking",
        "booking_reference",
        "reservation",
        "reservation_id",
        "flight_number",
        "origin",
        "destination",
        "origin_airport",
        "destination_airport",
        "departure",
        "departure_at",
        "arrival",
        "arrival_at",
        "location",
        "location_text",
        "venue",
        "address",
        "attendee",
        "attendees",
        "organizer",
        "guest",
        "guests",
        "contact",
        "contacts",
        "email",
        "phone",
        "medical",
        "birthday",
        "funeral",
        "meeting",
        "friend_event",
    }
)
_FORBIDDEN_KEY_PARTS = frozenset(
    {
        "attendee",
        "attendees",
        "birthday",
        "booking",
        "contact",
        "contacts",
        "description",
        "flight",
        "friend",
        "funeral",
        "guest",
        "guests",
        "itinerary",
        "location",
        "medical",
        "meeting",
        "notes",
        "organizer",
        "passenger",
        "reservation",
        "route",
        "ticket",
        "title",
        "transcript",
        "venue",
    }
)


class JobType(StrEnum):
    MAP_OBSERVATION = "map_observation"
    CLASSIFY_CALENDAR = "classify_calendar"
    RESOLVE_YOUTUBE_CHANNEL = "resolve_youtube_channel"
    RECOMPUTE_USER = "recompute_user"
    BUILD_MEMORIES = "build_memories"
    COMPUTE_DYAD = "compute_dyad"
    RENDER_BIO = "render_bio"
    RENDER_ICEBREAKER = "render_icebreaker"
    MINE_TERMS = "mine_terms"
    REFRESH_EXTERNAL_ENTITY = "refresh_external_entity"
    DERIVE_FITNESS_HABITS = "derive_fitness_habits"


class DyadPurpose(StrEnum):
    BIO = "bio"
    ICEBREAKER = "icebreaker"
    BOTH = "both"


class DataUsePurpose(StrEnum):
    GENERAL_SOCIAL = "general_social"
    FITNESS_CONNECTION = "fitness_connection"


class JobContractError(ValueError):
    """Safe validation failure that never includes a payload value."""

    def __init__(
        self,
        code: str,
        *,
        job_type: str | None = None,
        field: str | None = None,
    ) -> None:
        self.code = code
        self.job_type = job_type
        self.field = field
        parts = [code]
        if job_type in {item.value for item in JobType}:
            parts.append(job_type)
        # ``field`` remains available for local branching/tests, but exception
        # text is safe to persist even when an attacker supplied the key.
        super().__init__(":".join(parts))


class _PayloadMixin:
    """Serialize a validated dataclass back to canonical JSON-compatible data."""

    def as_payload(self) -> dict[str, object]:
        result: dict[str, object] = {}
        for item in fields(self):  # type: ignore[arg-type]
            value = getattr(self, item.name)
            if isinstance(value, UUID):
                result[item.name] = str(value)
            elif isinstance(value, StrEnum):
                result[item.name] = value.value
            elif value is not None:
                result[item.name] = value
        return result


@dataclass(frozen=True, slots=True)
class MapObservationPayload(_PayloadMixin):
    observation_id: UUID
    user_id: UUID
    input_revision: int
    semantic_run_id: UUID
    ontology_version_id: UUID
    resolver_model_id: UUID


@dataclass(frozen=True, slots=True)
class ClassifyCalendarPayload(_PayloadMixin):
    observation_id: UUID
    user_id: UUID
    input_revision: int
    ontology_version_id: UUID
    classifier_model_id: UUID


@dataclass(frozen=True, slots=True)
class ResolveYouTubeChannelPayload(_PayloadMixin):
    youtube_channel_row_id: UUID
    youtube_channel_id: str
    ontology_version_id: UUID
    resolver_model_id: UUID
    resolution_version: str


@dataclass(frozen=True, slots=True)
class RecomputeUserPayload(_PayloadMixin):
    user_id: UUID
    input_revision: int
    ontology_version_id: UUID
    resolver_model_id: UUID
    scorer_model_id: UUID
    embedding_model_id: UUID | None = None


@dataclass(frozen=True, slots=True)
class BuildMemoriesPayload(_PayloadMixin):
    user_id: UUID
    input_revision: int
    ontology_version_id: UUID
    builder_model_id: UUID
    presentation_version: str


@dataclass(frozen=True, slots=True)
class ComputeDyadPayload(_PayloadMixin):
    viewer_user_id: UUID
    subject_user_id: UUID
    viewer_revision: int
    subject_revision: int
    ontology_version_id: UUID
    ranker_model_id: UUID
    run_purpose: DyadPurpose
    data_use_purpose: DataUsePurpose = DataUsePurpose.GENERAL_SOCIAL


@dataclass(frozen=True, slots=True)
class RenderBioPayload(_PayloadMixin):
    dyad_run_id: UUID
    viewer_user_id: UUID
    subject_user_id: UUID
    viewer_revision: int
    subject_revision: int
    renderer_model_id: UUID
    presentation_version: str


@dataclass(frozen=True, slots=True)
class RenderIcebreakerPayload(_PayloadMixin):
    match_authorization_id: UUID
    dyad_run_id: UUID
    viewer_user_id: UUID
    subject_user_id: UUID
    viewer_revision: int
    subject_revision: int
    renderer_model_id: UUID
    template_version: str


@dataclass(frozen=True, slots=True)
class MineTermsPayload(_PayloadMixin):
    aggregate_snapshot_id: UUID
    base_ontology_version_id: UUID
    miner_model_id: UUID
    minimum_distinct_users: int
    mining_policy_version: str


@dataclass(frozen=True, slots=True)
class RefreshExternalEntityPayload(_PayloadMixin):
    external_entity_id: UUID
    refresher_version: str


@dataclass(frozen=True, slots=True)
class DeriveFitnessHabitsPayload(_PayloadMixin):
    user_id: UUID
    input_revision: int
    fitness_snapshot_id: UUID
    builder_model_id: UUID
    policy_version: str


JobPayload: TypeAlias = (
    MapObservationPayload
    | ClassifyCalendarPayload
    | ResolveYouTubeChannelPayload
    | RecomputeUserPayload
    | BuildMemoriesPayload
    | ComputeDyadPayload
    | RenderBioPayload
    | RenderIcebreakerPayload
    | MineTermsPayload
    | RefreshExternalEntityPayload
    | DeriveFitnessHabitsPayload
)


def _normalized_key(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", value.casefold()).strip("_")


def _is_forbidden_key(key: str) -> bool:
    normalized = _normalized_key(key)
    if (
        normalized in _FORBIDDEN_EXACT_KEYS
        or normalized == "raw"
        or normalized.startswith("raw_")
        or normalized.endswith("_raw")
    ):
        return True
    return bool(set(normalized.split("_")) & _FORBIDDEN_KEY_PARTS)


def _reject_private_fields(value: object, *, job_type: str) -> None:
    """Inspect nested keys iteratively, including currently unknown objects."""

    pending: list[object] = [value]
    seen: set[int] = set()
    while pending:
        item = pending.pop()
        if isinstance(item, Mapping):
            identity = id(item)
            if identity in seen:
                continue
            seen.add(identity)
            for key, child in item.items():
                if not isinstance(key, str):
                    raise JobContractError(
                        "invalid_payload_key", job_type=job_type
                    )
                if _is_forbidden_key(key):
                    raise JobContractError(
                        "forbidden_private_field",
                        job_type=job_type,
                        field=_normalized_key(key),
                    )
                pending.append(child)
        elif isinstance(item, Sequence) and not isinstance(
            item, (str, bytes, bytearray)
        ):
            identity = id(item)
            if identity in seen:
                continue
            seen.add(identity)
            pending.extend(item)


def _uuid(value: object, field: str) -> UUID:
    if not isinstance(value, str) or not _CANONICAL_UUID.fullmatch(value):
        raise JobContractError("invalid_uuid", field=field)
    try:
        return UUID(value)
    except ValueError as error:  # pragma: no cover - regex is a first guard
        raise JobContractError("invalid_uuid", field=field) from error


def _revision(value: object, field: str) -> int:
    if type(value) is not int or not 0 <= value <= MAX_DATABASE_REVISION:
        raise JobContractError("invalid_revision", field=field)
    return value


def _version(value: object, field: str) -> str:
    if not isinstance(value, str) or not _VERSION.fullmatch(value):
        raise JobContractError("invalid_version", field=field)
    return value


def _fitness_policy_version(value: object, field: str) -> str:
    parsed = _version(value, field)
    if parsed != HEALTHKIT_POLICY_VERSION:
        raise JobContractError("unsupported_fitness_policy_version", field=field)
    return parsed


def _youtube_channel_id(value: object, field: str) -> str:
    if not isinstance(value, str) or not _YOUTUBE_CHANNEL_ID.fullmatch(value):
        raise JobContractError("invalid_youtube_channel_id", field=field)
    return value


def _dyad_purpose(value: object, field: str) -> DyadPurpose:
    if not isinstance(value, str):
        raise JobContractError("invalid_run_purpose", field=field)
    try:
        return DyadPurpose(value)
    except ValueError as error:
        raise JobContractError("invalid_run_purpose", field=field) from error


def _data_use_purpose(value: object, field: str) -> DataUsePurpose:
    if not isinstance(value, str):
        raise JobContractError("invalid_data_use_purpose", field=field)
    try:
        return DataUsePurpose(value)
    except ValueError as error:
        raise JobContractError("invalid_data_use_purpose", field=field) from error


def _minimum_distinct_users(value: object, field: str) -> int:
    if (
        type(value) is not int
        or not MIN_TERM_MINING_USERS <= value <= MAX_DATABASE_INTEGER
    ):
        raise JobContractError("invalid_privacy_threshold", field=field)
    return value


Parser: TypeAlias = Callable[[object, str], object]
P = TypeVar("P", bound=JobPayload)


@dataclass(frozen=True, slots=True)
class JobContract(Generic[P]):
    """One closed payload schema and its cross-field invariant."""

    job_type: JobType
    payload_type: type[P]
    required_fields: Mapping[str, Parser]
    optional_fields: Mapping[str, Parser]
    purpose: str
    contract_version: int = 1
    cross_validator: Callable[[P], None] | None = None

    @property
    def allowed_fields(self) -> frozenset[str]:
        return frozenset((*self.required_fields, *self.optional_fields))

    def validate(self, payload: Mapping[str, object]) -> P:
        if not isinstance(payload, Mapping):
            raise JobContractError(
                "payload_not_object", job_type=self.job_type.value
            )
        _reject_private_fields(payload, job_type=self.job_type.value)
        payload_keys = set(payload)
        if any(not isinstance(key, str) for key in payload_keys):
            raise JobContractError(
                "invalid_payload_key", job_type=self.job_type.value
            )
        unknown = sorted(payload_keys - self.allowed_fields)
        if unknown:
            raise JobContractError(
                "unknown_payload_field",
                job_type=self.job_type.value,
                field=unknown[0],
            )
        missing = sorted(set(self.required_fields) - payload_keys)
        if missing:
            raise JobContractError(
                "missing_payload_field",
                job_type=self.job_type.value,
                field=missing[0],
            )

        parsed: dict[str, object] = {}
        for field, parser in self.required_fields.items():
            try:
                parsed[field] = parser(payload[field], field)
            except JobContractError as error:
                raise JobContractError(
                    error.code, job_type=self.job_type.value, field=error.field
                ) from error
        for field, parser in self.optional_fields.items():
            if field not in payload:
                continue
            try:
                parsed[field] = parser(payload[field], field)
            except JobContractError as error:
                raise JobContractError(
                    error.code, job_type=self.job_type.value, field=error.field
                ) from error

        result = self.payload_type(**parsed)  # type: ignore[arg-type]
        if self.cross_validator is not None:
            try:
                self.cross_validator(result)
            except JobContractError as error:
                raise JobContractError(
                    error.code, job_type=self.job_type.value, field=error.field
                ) from error
        return result


def _distinct_dyad(payload: object) -> None:
    if getattr(payload, "viewer_user_id") == getattr(payload, "subject_user_id"):
        raise JobContractError("same_user_dyad")


def _fields(**items: Parser) -> Mapping[str, Parser]:
    return MappingProxyType(dict(items))


_CONTRACT_SEQUENCE: tuple[JobContract[Any], ...] = (
    JobContract(
        JobType.MAP_OBSERVATION,
        MapObservationPayload,
        _fields(
            observation_id=_uuid,
            user_id=_uuid,
            input_revision=_revision,
            semantic_run_id=_uuid,
            ontology_version_id=_uuid,
            resolver_model_id=_uuid,
        ),
        _fields(),
        "Map one durable observation in an exact-revision semantic run.",
    ),
    JobContract(
        JobType.CLASSIFY_CALENDAR,
        ClassifyCalendarPayload,
        _fields(
            observation_id=_uuid,
            user_id=_uuid,
            input_revision=_revision,
            ontology_version_id=_uuid,
            classifier_model_id=_uuid,
        ),
        _fields(),
        "Load and classify one private Calendar observation by ID.",
    ),
    JobContract(
        JobType.RESOLVE_YOUTUBE_CHANNEL,
        ResolveYouTubeChannelPayload,
        _fields(
            youtube_channel_row_id=_uuid,
            youtube_channel_id=_youtube_channel_id,
            ontology_version_id=_uuid,
            resolver_model_id=_uuid,
            resolution_version=_version,
        ),
        _fields(),
        "Resolve one stable provider channel ID under a pinned resolver.",
    ),
    JobContract(
        JobType.RECOMPUTE_USER,
        RecomputeUserPayload,
        _fields(
            user_id=_uuid,
            input_revision=_revision,
            ontology_version_id=_uuid,
            resolver_model_id=_uuid,
            scorer_model_id=_uuid,
        ),
        # Absence means the run does not use embeddings.  Explicit JSON null
        # is rejected so one semantic payload has one canonical encoding.
        _fields(embedding_model_id=_uuid),
        "Recompute one user's semantic state at an exact input revision.",
    ),
    JobContract(
        JobType.BUILD_MEMORIES,
        BuildMemoriesPayload,
        _fields(
            user_id=_uuid,
            input_revision=_revision,
            ontology_version_id=_uuid,
            builder_model_id=_uuid,
            presentation_version=_version,
        ),
        _fields(),
        "Build a Memories snapshot from exact-revision assertions.",
    ),
    JobContract(
        JobType.COMPUTE_DYAD,
        ComputeDyadPayload,
        _fields(
            viewer_user_id=_uuid,
            subject_user_id=_uuid,
            viewer_revision=_revision,
            subject_revision=_revision,
            ontology_version_id=_uuid,
            ranker_model_id=_uuid,
            run_purpose=_dyad_purpose,
        ),
        _fields(data_use_purpose=_data_use_purpose),
        "Compute a directional dyad pinned to both users' revisions.",
        cross_validator=_distinct_dyad,
    ),
    JobContract(
        JobType.RENDER_BIO,
        RenderBioPayload,
        _fields(
            dyad_run_id=_uuid,
            viewer_user_id=_uuid,
            subject_user_id=_uuid,
            viewer_revision=_revision,
            subject_revision=_revision,
            renderer_model_id=_uuid,
            presentation_version=_version,
        ),
        _fields(),
        "Render validated bio facts from a current directional dyad run.",
        cross_validator=_distinct_dyad,
    ),
    JobContract(
        JobType.RENDER_ICEBREAKER,
        RenderIcebreakerPayload,
        _fields(
            match_authorization_id=_uuid,
            dyad_run_id=_uuid,
            viewer_user_id=_uuid,
            subject_user_id=_uuid,
            viewer_revision=_revision,
            subject_revision=_revision,
            renderer_model_id=_uuid,
            template_version=_version,
        ),
        _fields(),
        "Render a deterministic frame from an authorized, current dyad.",
        cross_validator=_distinct_dyad,
    ),
    JobContract(
        JobType.MINE_TERMS,
        MineTermsPayload,
        _fields(
            aggregate_snapshot_id=_uuid,
            base_ontology_version_id=_uuid,
            miner_model_id=_uuid,
            minimum_distinct_users=_minimum_distinct_users,
            mining_policy_version=_version,
        ),
        _fields(),
        "Mine review candidates from a pre-thresholded aggregate snapshot.",
    ),
    JobContract(
        JobType.REFRESH_EXTERNAL_ENTITY,
        RefreshExternalEntityPayload,
        _fields(
            external_entity_id=_uuid,
            refresher_version=_version,
        ),
        _fields(),
        "Refresh one existing external entity; provider details load by ID.",
    ),
    JobContract(
        JobType.DERIVE_FITNESS_HABITS,
        DeriveFitnessHabitsPayload,
        _fields(
            user_id=_uuid,
            input_revision=_revision,
            fitness_snapshot_id=_uuid,
            builder_model_id=_uuid,
            policy_version=_fitness_policy_version,
        ),
        _fields(),
        "Derive purpose-limited fitness habits from a private feature snapshot.",
    ),
)


class JobContractRegistry:
    """Immutable registry intended for enqueue and pre-handler validation."""

    def __init__(self, contracts: Iterable[JobContract[Any]]) -> None:
        indexed: dict[str, JobContract[Any]] = {}
        for contract in contracts:
            key = contract.job_type.value
            if key in indexed:
                raise ValueError("duplicate_job_contract")
            indexed[key] = contract
        expected = {item.value for item in JobType}
        if set(indexed) != expected:
            raise ValueError("incomplete_job_contract_registry")
        self._contracts: Mapping[str, JobContract[Any]] = MappingProxyType(indexed)

    @property
    def contracts(self) -> Mapping[str, JobContract[Any]]:
        return self._contracts

    @property
    def job_types(self) -> tuple[str, ...]:
        return tuple(item.value for item in JobType)

    def contract_for(self, job_type: str | JobType) -> JobContract[Any]:
        key = job_type.value if isinstance(job_type, JobType) else job_type
        if not isinstance(key, str) or key not in self._contracts:
            raise JobContractError("unknown_job_type", field="job_type")
        return self._contracts[key]

    def validate(
        self,
        job_type: str | JobType,
        payload: Mapping[str, object],
        *,
        queue_user_id: str | None = None,
    ) -> JobPayload:
        contract = self.contract_for(job_type)
        result = contract.validate(payload)
        if queue_user_id is not None:
            queue_user = _uuid(queue_user_id, "queue_user_id")
            payload_user = getattr(result, "user_id", None)
            if payload_user is None:
                payload_user = getattr(result, "viewer_user_id", None)
            if payload_user is not None and payload_user != queue_user:
                raise JobContractError(
                    "queue_user_mismatch",
                    job_type=contract.job_type.value,
                    field="queue_user_id",
                )
        return result


JOB_CONTRACT_REGISTRY = JobContractRegistry(_CONTRACT_SEQUENCE)
DEFAULT_JOB_CONTRACT_REGISTRY = JOB_CONTRACT_REGISTRY
JOB_CONTRACTS = JOB_CONTRACT_REGISTRY.contracts
REQUIRED_JOB_TYPES = frozenset(item.value for item in JobType)


def validate_job_payload(
    job_type: str | JobType,
    payload: Mapping[str, object],
    *,
    queue_user_id: str | None = None,
) -> JobPayload:
    """Validate and normalize a queue payload before selecting a handler."""

    return JOB_CONTRACT_REGISTRY.validate(
        job_type, payload, queue_user_id=queue_user_id
    )


__all__ = [
    "BuildMemoriesPayload",
    "ClassifyCalendarPayload",
    "ComputeDyadPayload",
    "DEFAULT_JOB_CONTRACT_REGISTRY",
    "DataUsePurpose",
    "DeriveFitnessHabitsPayload",
    "DyadPurpose",
    "JOB_CONTRACT_REGISTRY",
    "JOB_CONTRACTS",
    "JobContract",
    "JobContractError",
    "JobContractRegistry",
    "JobPayload",
    "JobType",
    "MIN_TERM_MINING_USERS",
    "MapObservationPayload",
    "MineTermsPayload",
    "REQUIRED_JOB_TYPES",
    "RecomputeUserPayload",
    "RefreshExternalEntityPayload",
    "RenderBioPayload",
    "RenderIcebreakerPayload",
    "ResolveYouTubeChannelPayload",
    "validate_job_payload",
]
