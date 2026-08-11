#!/usr/bin/env python3
"""Read the iOS envelope vocabulary out of Swift, so two things can check it.

`Written/Models/SemanticSource.swift` writes down a vocabulary the database
already owns: `semantic_private.sources.source_code`, and the keys of each
row's `action_weights`. Writing it down twice is only safe if something
compares the copies, and there are two different comparisons with two different
authorities:

  * **the distillers** — every `data_type` the app can emit must be mapped, or a
    new one reaches the vault as an unattributed row. Pure text, no database,
    so `semantic/tests/test_ios_envelope_contract.py` does it.
  * **the schema** — every action the mapping names must be one that source
    actually weighs. That is only knowable from the *final* state of the
    migration chain, five migrations touch `action_weights`, and reconstructing
    it by parsing SQL would be a third copy of the thing being checked. So
    `tools/replay_contracts.sh` asks the built database instead, via
    `--emit-sql` below.

Nothing here imports Swift or runs Xcode; it is deliberately a text reader, and
the build is what proves the Swift itself is valid.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

SEMANTIC_SOURCE_SWIFT = "Written/Models/SemanticSource.swift"
DISTILLER_GLOB = "Written/Services/*Distiller*.swift"
EXTRA_RECORD_SOURCES = ["Written/ViewModels/DistillViewModel.swift"]


# --------------------------------------------------------------------------
# Text handling


def strip_comments(text: str) -> str:
    """Line comments only. This file's Swift has no block comments, and a
    half-correct block-comment stripper that eats a `*/` inside a string
    literal is worse than not having one."""
    return "\n".join(re.sub(r"//.*$", "", line) for line in text.splitlines())


def strip_debug_blocks(text: str) -> str:
    """Drop `#if DEBUG` regions.

    The preview fixtures in `DistillViewModel` emit a `preview` data type and
    several real-looking ones, none of which ship or sync. Counting them would
    demand a mapping for a row that cannot exist in production — and, worse,
    would make the check pass for the wrong reason if a real data type were
    ever added inside such a block.
    """
    out, stack = [], []
    for line in text.splitlines():
        bare = line.strip()
        if bare.startswith("#if"):
            stack.append("DEBUG" in bare and not bare.startswith("#if !"))
        elif bare.startswith("#endif"):
            if stack:
                stack.pop()
            continue
        elif bare.startswith("#else") and stack:
            stack[-1] = not stack[-1]
            continue
        if not any(stack):
            out.append(line)
    return "\n".join(out)


def _balanced(text: str, open_at: int) -> str:
    """The substring inside the bracket that opens at `open_at`."""
    depth, i = 0, open_at
    while i < len(text):
        if text[i] == "[":
            depth += 1
        elif text[i] == "]":
            depth -= 1
            if depth == 0:
                return text[open_at + 1 : i]
        i += 1
    raise ValueError("unbalanced bracket")


# --------------------------------------------------------------------------
# Swift readers


def enum_cases(text: str, enum_name: str) -> dict[str, str]:
    """`case appleMusic = "apple_music"` and bare `case spotify` alike.

    A bare case takes its own name as the raw value, which is Swift's rule and
    is why half the cases in these enums have no `=`.
    """
    match = re.search(
        rf"enum {enum_name}[^{{]*\{{(.*?)\n\}}", text, re.S
    )
    if not match:
        raise ValueError(f"enum {enum_name} not found")
    cases: dict[str, str] = {}
    for line in match.group(1).splitlines():
        found = re.match(r'\s*case (\w+)(?:\s*=\s*"([^"]+)")?\s*$', line)
        if found:
            cases[found.group(1)] = found.group(2) or found.group(1)
    return cases


def parse_mapping(text: str) -> dict[str, dict[str, tuple]]:
    """`SemanticSource.actionsByDataType`, keyed by `source_code`.

    Values are `("actions", [...])`, `("unweighted", name)` or
    `("not_an_action", reason)` — the three cases of `ActionMapping`, kept
    distinct because "we have not decided" and "there is nothing to decide" are
    different states and collapsing them loses the list of things still owed a
    decision.
    """
    sources = enum_cases(text, "SemanticSource")
    actions = enum_cases(text, "SemanticAction")

    anchor = text.index("actionsByDataType")
    literal = _balanced(text, text.index("[", text.index("=", anchor)))

    mapping: dict[str, dict[str, tuple]] = {}
    for found in re.finditer(r"\.(\w+):\s*\[", literal):
        case = found.group(1)
        if case not in sources:
            raise ValueError(f"mapping names unknown source case .{case}")
        body = _balanced(literal, found.end() - 1)
        entries: dict[str, tuple] = {}
        for entry in re.finditer(
            r'"(\w+)":\s*\.(?:actions\(\[([^\]]*)\]\)'
            r'|unweighted\("([^"]*)"\)'
            r"|notAnAction\(\.(\w+)\))",
            body,
        ):
            data_type, acts, unweighted, reason = entry.groups()
            if acts is not None:
                names = []
                for raw in re.findall(r"\.(\w+)", acts):
                    if raw not in actions:
                        raise ValueError(f"mapping names unknown action .{raw}")
                    names.append(actions[raw])
                entries[data_type] = ("actions", names)
            elif unweighted is not None:
                entries[data_type] = ("unweighted", unweighted)
            else:
                entries[data_type] = ("not_an_action", reason)
        mapping[sources[case]] = entries
    return mapping


def app_source_codes(text: str) -> dict[str, str]:
    """`SemanticSource.appSourceCode`, as `{app string: source_code}`.

    Reads the `switch` rather than assuming identity, because it is not:
    `health` is what every distiller writes and `healthkit` is what the
    database calls it.
    """
    sources = enum_cases(text, "SemanticSource")
    body = re.search(r"var appSourceCode: String \{(.*?)\n    \}", text, re.S)
    if not body:
        raise ValueError("appSourceCode not found")
    overrides = {}
    for case, value in re.findall(
        r'case \.(\w+): return "([^"]+)"', body.group(1)
    ):
        overrides[sources[case]] = value
    return {overrides.get(code, code): code for code in sources.values()}


def distiller_data_types(repo: pathlib.Path) -> dict[str, set[str]]:
    """Every `data_type` the shipping app can emit, per file.

    Per file rather than per source because a distiller is not one-to-one with
    a source — `AppleMusicDistiller` also writes a `user` row for the
    subscription state, and `DistillViewModel` writes the four profile answers.
    Which source a given literal belongs to is not decidable by text, so the
    check this feeds is the one that does not need to know: *some* source must
    map it.
    """
    found: dict[str, set[str]] = {}
    paths = sorted(repo.glob(DISTILLER_GLOB))
    paths += [repo / name for name in EXTRA_RECORD_SOURCES]
    for path in paths:
        text = strip_debug_blocks(strip_comments(path.read_text(encoding="utf-8")))
        types = set(re.findall(r'dataType:\s*"([a-z0-9_]+)"', text))
        if types:
            found[str(path.relative_to(repo))] = types
    return found


def semantic_data_types(text: str) -> dict[str, str]:
    """`SemanticSource.semanticDataType`, as `{"source/app_type": schema_type}`.

    The second translation seam, beside `appSourceCode`. It exists because the
    run-item guard requires the raw record, the scope manifest and the
    observation to carry the same `data_type` — so a calendar row has to say
    `calendar_event` from the device onward, and the distiller's `event` cannot
    be corrected downstream.
    """
    body = re.search(
        r"func semanticDataType\(for appDataType: String\) -> String \{(.*?)\n    \}",
        text, re.S,
    )
    if not body:
        raise ValueError("semanticDataType not found")
    mapped: dict[str, str] = {}
    case_pattern = r'case ((?:\(\.\w+, "[a-z_]+"\),?\s*)+):\s*\n\s*return "([a-z_]+)"'
    pair_pattern = r'\(\.(\w+), "([a-z_]+)"\)'
    for cases, result in re.findall(case_pattern, body.group(1)):
        for source, app_type in re.findall(pair_pattern, cases):
            mapped[f"{source}/{app_type}"] = result
    return mapped


def distiller_source_codes(repo: pathlib.Path) -> set[str]:
    """Every `source:` string literal the shipping app writes."""
    codes: set[str] = set()
    paths = sorted(repo.glob(DISTILLER_GLOB))
    paths += [repo / name for name in EXTRA_RECORD_SOURCES]
    for path in paths:
        text = strip_debug_blocks(strip_comments(path.read_text(encoding="utf-8")))
        codes |= set(re.findall(r'source:\s*"([a-z0-9_]+)"', text))
    return codes


def load(repo: pathlib.Path) -> dict:
    text = strip_comments((repo / SEMANTIC_SOURCE_SWIFT).read_text(encoding="utf-8"))
    return {
        "sources": sorted(enum_cases(text, "SemanticSource").values()),
        "actions": sorted(enum_cases(text, "SemanticAction").values()),
        "app_source_codes": app_source_codes(text),
        "semantic_data_types": semantic_data_types(text),
        "mapping": parse_mapping(text),
        "distiller_data_types": {
            name: sorted(types)
            for name, types in distiller_data_types(repo).items()
        },
        "distiller_source_codes": sorted(distiller_source_codes(repo)),
    }


# --------------------------------------------------------------------------
# CLI


def emit_sql(data: dict) -> str:
    """A `values` list of every `(source_code, action_type)` the app can claim.

    Consumed by `tools/replay_contracts.sh`, which joins it against the built
    `semantic_private.sources` — the only place the final `action_weights` for
    a source exists, five migrations having had a hand in it.
    """
    rows = []
    for source, entries in sorted(data["mapping"].items()):
        for data_type, value in sorted(entries.items()):
            if value[0] != "actions":
                continue
            for action in value[1]:
                rows.append(
                    f"  ('{source}', '{data_type}', '{action}')"
                )
    if not rows:
        raise ValueError("no mapped actions found — the parser is broken")
    return (
        "create temporary table ios_envelope_actions"
        " (source_code text, data_type text, action_type text);\n"
        "insert into ios_envelope_actions values\n"
        + ",\n".join(rows)
        + ";\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".", help="repository root")
    parser.add_argument(
        "--emit-sql",
        action="store_true",
        help="print the (source, data_type, action) triples as SQL",
    )
    args = parser.parse_args()
    data = load(pathlib.Path(args.repo).resolve())
    print(emit_sql(data) if args.emit_sql else json.dumps(data, indent=2, default=sorted))
    return 0


if __name__ == "__main__":
    sys.exit(main())
