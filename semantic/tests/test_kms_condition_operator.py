"""The vault-decrypt condition uses a set operator, and only one of them.

**This has cost a round already.** `semantic/docs/KMS_DESIGN.md` records the
first time: `kms:EncryptionContextKeys` is multivalued, a bare `StringEquals`
never matches one, and every vault action came back `implicitDeny` while the
policy JSON looked perfectly correct. It then recurred in
`aws/worker/stack.yaml`, written from the same intuition.

Which set operator is not cosmetic. `ForAllValues:StringEquals` is vacuously
true for an *empty* encryption context, so it permits exactly the unconditioned
decrypt the condition exists to forbid — the failure that reads as working.
`ForAnyValue:StringEquals` requires the key to be present.

So the rule is pinned here rather than remembered: a bare operator fails loudly
in CI instead of quietly in IAM, and the `ForAllValues` spelling is refused
outright rather than being merely undocumented.
"""

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CONTEXT_KEY = "kms:EncryptionContextKeys"
REQUIRED = "ForAnyValue:StringEquals"

#: A condition operator on its own line, captured with its indentation so the
#: enclosing one can be found by walking outward rather than by guessing.
OPERATOR = re.compile(r"^(\s*)((?:ForAnyValue:|ForAllValues:)?String\w+):\s*$")


def _enclosing_operator(lines: list[str], index: int) -> str | None:
    """The condition operator the line at `index` sits under."""
    indent = len(lines[index]) - len(lines[index].lstrip())
    for line in reversed(lines[:index]):
        match = OPERATOR.match(line)
        if match and len(match.group(1)) < indent:
            return match.group(2)
    return None


class KmsConditionOperatorTests(unittest.TestCase):
    def test_every_encryption_context_condition_uses_for_any_value(self) -> None:
        checked = 0
        for template in sorted((REPO / "aws").rglob("*.yaml")):
            lines = template.read_text(encoding="utf-8").splitlines()
            for index, line in enumerate(lines):
                if CONTEXT_KEY not in line or line.lstrip().startswith("#"):
                    continue
                checked += 1
                operator = _enclosing_operator(lines, index)
                self.assertEqual(
                    REQUIRED, operator,
                    f"{template.relative_to(REPO)}:{index + 1} conditions "
                    f"{CONTEXT_KEY} under {operator!r}. A bare operator never "
                    f"matches a multivalued key and denies every vault read; "
                    f"ForAllValues is vacuously true for an empty context and "
                    f"permits the decrypt this forbids. Use {REQUIRED}.")

        # **A test that found nothing to check passes for the wrong reason.**
        # The condition moving to a template this does not read is exactly the
        # change that should fail here.
        self.assertGreater(
            checked, 0,
            f"no template conditions on {CONTEXT_KEY}; either the vault-decrypt "
            f"grant lost its condition or it moved somewhere this cannot see")


if __name__ == "__main__":
    unittest.main()
