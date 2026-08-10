"""Deterministic consistency audit for the duplicated V0.1 ontology seeds.

The Python decision graph reads ``ontology/seed_*.csv`` while PostgreSQL is
bootstrapped by named VALUES CTEs in ``sql/003_seed.sql``.  Those are two
physical representations of one shared catalog.  This module parses both with
the standard library and compares exact concept, label, and edge semantics.

The following SQL-only configuration is intentionally outside this shared
catalog and must not be synthesized from the CSV files: relation type
definitions, source/provider policy, ontology-version lifecycle, model and
embedding registrations, and motif execution configuration.  Their tables are
listed in ``INTENTIONAL_SQL_ONLY_SEED_TABLES`` so the boundary is executable,
not an undocumented exception.
"""

from __future__ import annotations

import csv
import re
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass, fields, is_dataclass
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import TypeVar


# The reference chain names its own schema `private`; the Written application
# maps every semantic object onto `semantic_private`, because this app already
# owns a `private` schema holding unrelated push and collaborator objects. The
# name is a single constant so the tuple below, the tests that assert against
# it, and anything else that has to name the schema all move together — a
# hand-edit in two places is how a rename half-applies and still passes.
SEMANTIC_PRIVATE_SCHEMA = "semantic_private"

INTENTIONAL_SQL_ONLY_SEED_TABLES = (
    "ontology.relation_types",
    f"{SEMANTIC_PRIVATE_SCHEMA}.sources",
    "ontology.versions",
    "ontology.model_versions",
    "ontology.embedding_models",
    "ontology.motif_rules",
)

_CONCEPT_COLUMNS = (
    "concept_key",
    "preferred_label",
    "concept_kind",
    "sensitivity",
    "inference_policy",
    "status",
    "notes",
)
_SQL_CONCEPT_COLUMNS = (
    "concept_key",
    "preferred_label",
    "concept_kind",
    "sensitivity",
    "inference_policy",
    "status",
    "definition",
)
_ALIAS_COLUMNS = (
    "concept_key",
    "alias",
    "locale",
    "alias_type",
    "confidence",
)
_SQL_ALIAS_COLUMNS = (
    "concept_key",
    "label",
    "locale",
    "label_type",
    "confidence",
)
_EDGE_COLUMNS = (
    "subject_key",
    "predicate_key",
    "object_key",
    "confidence",
    "provenance_type",
    "status",
)

_DECIMAL_LITERAL = re.compile(
    r"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$"
)


class SeedConsistencyError(ValueError):
    pass


@dataclass(frozen=True, slots=True, order=True)
class ConceptSeed:
    concept_key: str
    preferred_label: str
    concept_kind: str
    sensitivity: str
    inference_policy: str
    status: str
    definition: str


@dataclass(frozen=True, slots=True, order=True)
class AliasSeed:
    concept_key: str
    alias: str
    locale: str
    alias_type: str
    confidence: Decimal


@dataclass(frozen=True, slots=True, order=True)
class EdgeSeed:
    subject_key: str
    predicate_key: str
    object_key: str
    confidence: Decimal
    provenance_type: str
    status: str


@dataclass(frozen=True, slots=True)
class SeedCatalog:
    declared_concept_keys: tuple[str, ...]
    concepts: tuple[ConceptSeed, ...]
    aliases: tuple[AliasSeed, ...]
    edges: tuple[EdgeSeed, ...]


@dataclass(frozen=True, slots=True, order=True)
class SeedDifference:
    section: str
    item_key: str
    field: str
    csv_value: str | None
    sql_value: str | None


def _decimal(value: object, *, context: str) -> Decimal:
    try:
        parsed = Decimal(str(value))
    except (InvalidOperation, ValueError) as error:
        raise SeedConsistencyError(f"invalid decimal in {context}") from error
    if not parsed.is_finite() or not Decimal("0") <= parsed <= Decimal("1"):
        raise SeedConsistencyError(f"out-of-range decimal in {context}")
    return parsed


def _required_text(value: object, *, context: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise SeedConsistencyError(f"missing text in {context}")
    return value


def _csv_rows(path: Path, expected_columns: tuple[str, ...]) -> tuple[dict[str, str], ...]:
    try:
        with path.open(encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle)
            if tuple(reader.fieldnames or ()) != expected_columns:
                raise SeedConsistencyError(
                    f"unexpected columns in {path.name}: {reader.fieldnames!r}"
                )
            return tuple(dict(row) for row in reader)
    except OSError as error:
        raise SeedConsistencyError(f"cannot read {path.name}") from error


T = TypeVar("T")


def _unique_sorted(
    items: Iterable[T],
    *,
    key: Callable[[T], object],
    section: str,
) -> tuple[T, ...]:
    indexed: dict[object, T] = {}
    for item in items:
        identity = key(item)
        if identity in indexed:
            raise SeedConsistencyError(f"duplicate {section} seed")
        indexed[identity] = item
    return tuple(sorted(indexed.values()))


def _validate_catalog(catalog: SeedCatalog, *, source: str) -> SeedCatalog:
    concept_keys = {item.concept_key for item in catalog.concepts}
    if set(catalog.declared_concept_keys) != concept_keys:
        raise SeedConsistencyError(f"{source} concept declaration/revision drift")
    if any(alias.concept_key not in concept_keys for alias in catalog.aliases):
        raise SeedConsistencyError(f"{source} alias has unknown concept")
    if any(
        edge.subject_key not in concept_keys or edge.object_key not in concept_keys
        for edge in catalog.edges
    ):
        raise SeedConsistencyError(f"{source} edge has unknown endpoint")
    return catalog


def load_csv_seed_catalog(seed_dir: str | Path) -> SeedCatalog:
    root = Path(seed_dir)
    concept_rows = _csv_rows(root / "seed_concepts.csv", _CONCEPT_COLUMNS)
    alias_rows = _csv_rows(root / "seed_aliases.csv", _ALIAS_COLUMNS)
    edge_rows = _csv_rows(root / "seed_relations.csv", _EDGE_COLUMNS)

    concepts = _unique_sorted(
        (
            ConceptSeed(
                concept_key=_required_text(
                    row["concept_key"], context="CSV concept key"
                ),
                preferred_label=_required_text(
                    row["preferred_label"], context="CSV preferred label"
                ),
                concept_kind=_required_text(
                    row["concept_kind"], context="CSV concept kind"
                ),
                sensitivity=_required_text(
                    row["sensitivity"], context="CSV sensitivity"
                ),
                inference_policy=_required_text(
                    row["inference_policy"], context="CSV inference policy"
                ),
                status=_required_text(row["status"], context="CSV concept status"),
                definition=_required_text(
                    row["notes"], context="CSV concept definition"
                ),
            )
            for row in concept_rows
        ),
        key=lambda item: item.concept_key,
        section="CSV concept",
    )
    aliases = _unique_sorted(
        (
            AliasSeed(
                concept_key=_required_text(
                    row["concept_key"], context="CSV alias concept"
                ),
                alias=_required_text(row["alias"], context="CSV alias"),
                locale=_required_text(row["locale"], context="CSV alias locale"),
                alias_type=_required_text(
                    row["alias_type"], context="CSV alias type"
                ),
                confidence=_decimal(
                    row["confidence"], context="CSV alias confidence"
                ),
            )
            for row in alias_rows
        ),
        key=lambda item: (
            item.concept_key,
            item.alias,
            item.locale,
            item.alias_type,
        ),
        section="CSV alias",
    )
    edges = _unique_sorted(
        (
            EdgeSeed(
                subject_key=_required_text(
                    row["subject_key"], context="CSV edge subject"
                ),
                predicate_key=_required_text(
                    row["predicate_key"], context="CSV edge predicate"
                ),
                object_key=_required_text(
                    row["object_key"], context="CSV edge object"
                ),
                confidence=_decimal(
                    row["confidence"], context="CSV edge confidence"
                ),
                provenance_type=_required_text(
                    row["provenance_type"], context="CSV edge provenance"
                ),
                status=_required_text(row["status"], context="CSV edge status"),
            )
            for row in edge_rows
        ),
        key=lambda item: (
            item.subject_key,
            item.predicate_key,
            item.object_key,
            item.provenance_type,
        ),
        section="CSV edge",
    )
    return _validate_catalog(
        SeedCatalog(
            declared_concept_keys=tuple(item.concept_key for item in concepts),
            concepts=concepts,
            aliases=aliases,
            edges=edges,
        ),
        source="CSV",
    )


def _matching_parenthesis(text: str, opening: int) -> int:
    if opening >= len(text) or text[opening] != "(":
        raise SeedConsistencyError("SQL parser expected opening parenthesis")
    depth = 0
    in_string = False
    index = opening
    while index < len(text):
        char = text[index]
        if in_string:
            if char == "'":
                if index + 1 < len(text) and text[index + 1] == "'":
                    index += 2
                    continue
                in_string = False
        elif char == "'":
            in_string = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index
            if depth < 0:
                break
        index += 1
    raise SeedConsistencyError("unbalanced SQL seed parentheses or string")


def _split_sql_fields(value: str) -> tuple[str, ...]:
    result: list[str] = []
    start = 0
    depth = 0
    in_string = False
    index = 0
    while index < len(value):
        char = value[index]
        if in_string:
            if char == "'":
                if index + 1 < len(value) and value[index + 1] == "'":
                    index += 2
                    continue
                in_string = False
        elif char == "'":
            in_string = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        elif char == "," and depth == 0:
            result.append(value[start:index].strip())
            start = index + 1
        index += 1
    if in_string or depth != 0:
        raise SeedConsistencyError("invalid SQL seed field list")
    result.append(value[start:].strip())
    return tuple(result)


def _sql_literal(value: str) -> str | Decimal | None:
    stripped = value.strip()
    if stripped.casefold() == "null":
        return None
    if len(stripped) >= 2 and stripped[0] == "'" and stripped[-1] == "'":
        inner = stripped[1:-1]
        index = 0
        result: list[str] = []
        while index < len(inner):
            char = inner[index]
            if char == "'":
                if index + 1 >= len(inner) or inner[index + 1] != "'":
                    raise SeedConsistencyError("invalid SQL string literal")
                result.append("'")
                index += 2
                continue
            result.append(char)
            index += 1
        return "".join(result)
    if _DECIMAL_LITERAL.fullmatch(stripped):
        try:
            parsed = Decimal(stripped)
        except InvalidOperation as error:  # pragma: no cover - regex guards
            raise SeedConsistencyError("invalid SQL numeric literal") from error
        if not parsed.is_finite():
            raise SeedConsistencyError("non-finite SQL numeric literal")
        return parsed
    raise SeedConsistencyError("unsupported expression in shared SQL seed")


def _parse_values_rows(body: str) -> tuple[tuple[str | Decimal | None, ...], ...]:
    rows: list[tuple[str | Decimal | None, ...]] = []
    index = 0
    while index < len(body):
        while index < len(body) and (body[index].isspace() or body[index] == ","):
            index += 1
        if index == len(body):
            break
        if body[index] != "(":
            raise SeedConsistencyError("SQL VALUES seed must contain literal rows")
        closing = _matching_parenthesis(body, index)
        fields_text = _split_sql_fields(body[index + 1 : closing])
        rows.append(tuple(_sql_literal(value) for value in fields_text))
        index = closing + 1
    return tuple(rows)


def _extract_values_cte(
    sql: str,
    *,
    cte_name: str,
) -> tuple[tuple[str, ...], tuple[tuple[str | Decimal | None, ...], ...]]:
    match = re.search(rf"\bwith\s+{re.escape(cte_name)}\s*\(", sql, re.IGNORECASE)
    if match is None:
        raise SeedConsistencyError(f"missing SQL CTE: {cte_name}")
    header_open = match.end() - 1
    header_close = _matching_parenthesis(sql, header_open)
    columns = tuple(
        value.strip() for value in sql[header_open + 1 : header_close].split(",")
    )
    if not columns or any(not value for value in columns):
        raise SeedConsistencyError(f"invalid SQL CTE columns: {cte_name}")
    values_match = re.match(
        r"\s*as\s*\(\s*values\b",
        sql[header_close + 1 :],
        re.IGNORECASE,
    )
    if values_match is None:
        raise SeedConsistencyError(f"SQL CTE is not a VALUES seed: {cte_name}")
    absolute_start = header_close + 1 + values_match.start()
    group_open = sql.find("(", absolute_start, header_close + 1 + values_match.end())
    if group_open < 0:
        raise SeedConsistencyError(f"missing SQL VALUES group: {cte_name}")
    group_close = _matching_parenthesis(sql, group_open)
    body_start = header_close + 1 + values_match.end()
    rows = _parse_values_rows(sql[body_start:group_close])
    if not rows or any(len(row) != len(columns) for row in rows):
        raise SeedConsistencyError(f"SQL CTE row shape mismatch: {cte_name}")
    return columns, rows


def _row_mapping(
    columns: Sequence[str],
    row: Sequence[str | Decimal | None],
) -> Mapping[str, str | Decimal | None]:
    return dict(zip(columns, row, strict=True))


def _sql_text(
    row: Mapping[str, str | Decimal | None],
    field: str,
    *,
    context: str,
) -> str:
    return _required_text(row.get(field), context=context)


def load_sql_seed_catalog(sql_path: str | Path) -> SeedCatalog:
    path = Path(sql_path)
    try:
        sql = path.read_text(encoding="utf-8")
    except OSError as error:
        raise SeedConsistencyError(f"cannot read {path.name}") from error

    declared_columns, declared_values = _extract_values_cte(sql, cte_name="seed")
    if declared_columns != ("concept_key",):
        raise SeedConsistencyError("unexpected SQL concept declaration columns")
    declared = _unique_sorted(
        (
            _required_text(row[0], context="SQL declared concept key")
            for row in declared_values
        ),
        key=lambda item: item,
        section="SQL concept declaration",
    )

    concept_columns, concept_values = _extract_values_cte(
        sql, cte_name="revision_seed"
    )
    if concept_columns != _SQL_CONCEPT_COLUMNS:
        raise SeedConsistencyError("unexpected SQL concept revision columns")
    concepts = _unique_sorted(
        (
            ConceptSeed(
                concept_key=_sql_text(
                    row, "concept_key", context="SQL concept key"
                ),
                preferred_label=_sql_text(
                    row, "preferred_label", context="SQL preferred label"
                ),
                concept_kind=_sql_text(
                    row, "concept_kind", context="SQL concept kind"
                ),
                sensitivity=_sql_text(
                    row, "sensitivity", context="SQL sensitivity"
                ),
                inference_policy=_sql_text(
                    row, "inference_policy", context="SQL inference policy"
                ),
                status=_sql_text(row, "status", context="SQL concept status"),
                definition=_sql_text(
                    row, "definition", context="SQL concept definition"
                ),
            )
            for row in (
                _row_mapping(concept_columns, values)
                for values in concept_values
            )
        ),
        key=lambda item: item.concept_key,
        section="SQL concept revision",
    )

    alias_columns, alias_values = _extract_values_cte(sql, cte_name="label_seed")
    if alias_columns != _SQL_ALIAS_COLUMNS:
        raise SeedConsistencyError("unexpected SQL alias columns")
    aliases = _unique_sorted(
        (
            AliasSeed(
                concept_key=_sql_text(
                    row, "concept_key", context="SQL alias concept"
                ),
                alias=_sql_text(row, "label", context="SQL alias"),
                locale=_sql_text(row, "locale", context="SQL alias locale"),
                alias_type=_sql_text(
                    row, "label_type", context="SQL alias type"
                ),
                confidence=_decimal(
                    row.get("confidence"), context="SQL alias confidence"
                ),
            )
            for row in (
                _row_mapping(alias_columns, values) for values in alias_values
            )
        ),
        key=lambda item: (
            item.concept_key,
            item.alias,
            item.locale,
            item.alias_type,
        ),
        section="SQL alias",
    )

    edge_columns, edge_values = _extract_values_cte(sql, cte_name="edge_seed")
    if edge_columns != _EDGE_COLUMNS:
        raise SeedConsistencyError("unexpected SQL edge columns")
    edges = _unique_sorted(
        (
            EdgeSeed(
                subject_key=_sql_text(
                    row, "subject_key", context="SQL edge subject"
                ),
                predicate_key=_sql_text(
                    row, "predicate_key", context="SQL edge predicate"
                ),
                object_key=_sql_text(
                    row, "object_key", context="SQL edge object"
                ),
                confidence=_decimal(
                    row.get("confidence"), context="SQL edge confidence"
                ),
                provenance_type=_sql_text(
                    row, "provenance_type", context="SQL edge provenance"
                ),
                status=_sql_text(row, "status", context="SQL edge status"),
            )
            for row in (
                _row_mapping(edge_columns, values) for values in edge_values
            )
        ),
        key=lambda item: (
            item.subject_key,
            item.predicate_key,
            item.object_key,
            item.provenance_type,
        ),
        section="SQL edge",
    )
    return _validate_catalog(
        SeedCatalog(
            declared_concept_keys=declared,
            concepts=concepts,
            aliases=aliases,
            edges=edges,
        ),
        source="SQL",
    )


def _display(value: object) -> str:
    return str(value)


def _compare_section(
    section: str,
    csv_items: Sequence[object],
    sql_items: Sequence[object],
    *,
    key: Callable[[object], object],
) -> list[SeedDifference]:
    csv_by_key = {key(item): item for item in csv_items}
    sql_by_key = {key(item): item for item in sql_items}
    result: list[SeedDifference] = []
    for identity in sorted(set(csv_by_key) | set(sql_by_key), key=repr):
        csv_item = csv_by_key.get(identity)
        sql_item = sql_by_key.get(identity)
        item_key = repr(identity)
        if csv_item is None:
            result.append(
                SeedDifference(section, item_key, "item", None, _display(sql_item))
            )
            continue
        if sql_item is None:
            result.append(
                SeedDifference(section, item_key, "item", _display(csv_item), None)
            )
            continue
        if not is_dataclass(csv_item) or not is_dataclass(sql_item):
            if csv_item != sql_item:
                result.append(
                    SeedDifference(
                        section,
                        item_key,
                        "value",
                        _display(csv_item),
                        _display(sql_item),
                    )
                )
            continue
        for field in fields(csv_item):  # type: ignore[arg-type]
            left = getattr(csv_item, field.name)
            right = getattr(sql_item, field.name)
            if left != right:
                result.append(
                    SeedDifference(
                        section,
                        item_key,
                        field.name,
                        _display(left),
                        _display(right),
                    )
                )
    return result


def compare_seed_catalogs(
    csv_catalog: SeedCatalog,
    sql_catalog: SeedCatalog,
) -> tuple[SeedDifference, ...]:
    differences: list[SeedDifference] = []
    differences.extend(
        _compare_section(
            "declared_concepts",
            csv_catalog.declared_concept_keys,
            sql_catalog.declared_concept_keys,
            key=lambda item: item,
        )
    )
    differences.extend(
        _compare_section(
            "concepts",
            csv_catalog.concepts,
            sql_catalog.concepts,
            key=lambda item: item.concept_key,  # type: ignore[attr-defined]
        )
    )
    differences.extend(
        _compare_section(
            "aliases",
            csv_catalog.aliases,
            sql_catalog.aliases,
            key=lambda item: (
                item.concept_key,  # type: ignore[attr-defined]
                item.alias,  # type: ignore[attr-defined]
                item.locale,  # type: ignore[attr-defined]
                item.alias_type,  # type: ignore[attr-defined]
            ),
        )
    )
    differences.extend(
        _compare_section(
            "edges",
            csv_catalog.edges,
            sql_catalog.edges,
            key=lambda item: (
                item.subject_key,  # type: ignore[attr-defined]
                item.predicate_key,  # type: ignore[attr-defined]
                item.object_key,  # type: ignore[attr-defined]
                item.provenance_type,  # type: ignore[attr-defined]
            ),
        )
    )
    return tuple(sorted(differences))


def audit_seed_files(
    seed_dir: str | Path,
    sql_path: str | Path,
) -> tuple[SeedDifference, ...]:
    return compare_seed_catalogs(
        load_csv_seed_catalog(seed_dir),
        load_sql_seed_catalog(sql_path),
    )


__all__ = [
    "AliasSeed",
    "ConceptSeed",
    "EdgeSeed",
    "INTENTIONAL_SQL_ONLY_SEED_TABLES",
    "SEMANTIC_PRIVATE_SCHEMA",
    "SeedCatalog",
    "SeedConsistencyError",
    "SeedDifference",
    "audit_seed_files",
    "compare_seed_catalogs",
    "load_csv_seed_catalog",
    "load_sql_seed_catalog",
]
