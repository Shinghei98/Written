"""A module-level helper must still be reachable from the code that calls it.

## The failure this is about

`resolve.py` grew a module-level `identity()` to fix the mixed-representation
join that skipped 736 observations in silence. `resolve_user` already had a local
variable called `identity` — the run-identity dict, assigned near the top of the
function — so from that line onward the name referred to a `dict`.

**All four call sites are below it.** Every one raised
`TypeError: 'dict' object is not callable` on the first row it touched, from the
moment the fix shipped. The job failed, retried, and failed again.

`test_identifier_normalization.py` passed the whole time. It imports `identity`
and calls it directly, which proves the function is correct and says nothing
about whether the caller can see it. **A unit test of a helper cannot detect that
the helper has been shadowed at its call site** — the test and the caller resolve
the name in different scopes.

That is the same shape as the defect this codebase keeps recording: *a call that
can fail, a result nobody reads, and the symptom surfacing somewhere else.* Here
the symptom was a `TypeError` pointing at a dict comprehension that looked
completely innocent, three deploys after the cause.

## What is asserted

For each module-level function in the worker, that no function in the same file
rebinds its name — as a local assignment, a loop target, a comprehension
variable, a `with ... as`, an `except ... as` or an import. The check is by AST
rather than by grep, because `identity = {` and `for identity in ...` and
`with open(p) as identity:` are the same bug wearing three syntaxes.

Shadowing a *builtin* is not in scope: it is legal, common and usually harmless.
What is caught is shadowing something defined in the same module, which is the
case where the author almost certainly meant to call it.

**Parameters are excluded, and that came out of the first run.** It flagged
`handler.py`'s `_reporting(name, handler)`, which takes a parameter named
`handler` and calls exactly that — the module-level `handler()` is the Lambda
entrypoint and is not what it wants. A parameter is a deliberate signature whose
value the caller supplies; a local assignment is someone reaching for a name that
was already taken. Only the second is the bug this file is named after.
"""

from __future__ import annotations

import ast
import os
import pathlib

import pytest

REPOSITORY = os.environ.get("WRITTEN_REPOSITORY_PATH")

pytestmark = pytest.mark.skipif(
    not REPOSITORY, reason="WRITTEN_REPOSITORY_PATH is unset"
)


def _worker_modules():
    directory = pathlib.Path(REPOSITORY) / "aws" / "worker"
    if not directory.is_dir():
        pytest.fail(f"no worker directory at {directory}")
    return sorted(directory.glob("*.py"))


def _bound_names(function: ast.FunctionDef) -> set[str]:
    """Every name this function *assigns*, by any syntax that assigns one.

    Parameters are deliberately not counted — see the module docstring.
    """
    bound: set[str] = set()

    for node in ast.walk(function):
        # A nested def has its own scope; its *name* is still bound here.
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            if node is not function:
                bound.add(node.name)
            continue
        if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Store):
            bound.add(node.id)
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            for alias in node.names:
                bound.add(alias.asname or alias.name.split(".")[0])
        elif isinstance(node, ast.Global) or isinstance(node, ast.Nonlocal):
            # Declared global/nonlocal is the author saying "the outer one",
            # which is the opposite of shadowing.
            bound.difference_update(node.names)
    return bound


@pytest.mark.parametrize("path", _worker_modules(), ids=lambda p: p.name)
def test_no_function_shadows_a_module_level_helper(path):
    tree = ast.parse(path.read_text())

    helpers = {
        node.name
        for node in tree.body
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
    }
    if not helpers:
        pytest.skip(f"{path.name} defines no module-level function")

    offenders = []
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        # A helper legitimately rebinds its own name only in pathological code;
        # exclude it so recursion and decorators do not read as shadowing.
        shadowed = (_bound_names(node) & helpers) - {node.name}
        for name in sorted(shadowed):
            offenders.append(f"{path.name}:{node.lineno} {node.name}() shadows {name}()")

    assert not offenders, (
        "these functions rebind the name of a module-level function, so any call "
        "to it below that point raises TypeError at runtime while every unit "
        "test of the helper keeps passing: " + "; ".join(offenders)
    )
