"""What "the exact gateway implementation" is, as one definition.

`llm.gateway.revision` exists to *"bind semantic gate reports to the exact
gateway implementation"*. The obvious candidates cannot do that:

- **The image digest is circular.** The Dockerfile copies the compiled contract
  into the image — deliberately, because *"the gateway attests what it loaded and
  cannot attest a file it fetches at runtime"* — so a digest written into the
  contract is a hash of a layer containing the file that names it.
- **A git commit is circular for the same reason.** A commit's SHA cannot appear
  in a file that commit contains.

Both were placeholders for months for this reason rather than by neglect.

A **content hash of the implementation** has neither problem: the contract is not
among the files hashed, so nothing is hashing itself, and it binds more tightly
than a commit ever could — a commit SHA moves when an unrelated migration lands,
and does not move when the gateway is edited and the contract is not recompiled.
That second case is the one this exists to catch, and it is not hypothetical: the
gateway image was deployed at one commit and the transport corrected ten minutes
later at the next, leaving a recorded digest that could not prove parity with the
code it was supposed to describe.

`test_gateway_revision.py` recomputes this and compares it against the compiled
contract, so editing the transport without recompiling fails rather than drifts.
"""
from __future__ import annotations

import hashlib
import pathlib

#: The implementation, relative to the repository root. Everything here either
#: reaches the model, decides whether it may be reached, or shapes what comes
#: back; `semantic_contract.py` is deliberately absent, being the reader of the
#: file this value is written into.
GATEWAY_SOURCES = (
    "aws/gateway/handler.py",
    "aws/gateway/manifest.py",
    "aws/gateway/sagemaker_transport.py",
    "aws/gateway/ticket_store.py",
    "aws/gateway/server.py",
    "semantic/src/written_ontology/gateway.py",
    "semantic/src/written_ontology/gateway_http.py",
    # The validator and repair: they decide which answers survive, which this
    # session proved is release-significant — the offset repair changed the
    # accepted set without a single gateway.py line needing to.
    "semantic/src/written_ontology/mention_extract_v2.py",
)


def gateway_revision(repository: pathlib.Path) -> str:
    """A stable digest over the gateway implementation.

    The path is hashed alongside the bytes, so moving a file changes the answer
    — renaming a module is a change to the implementation even when no line of
    it moves.
    """
    digest = hashlib.sha256()
    for relative in sorted(GATEWAY_SOURCES):
        path = repository / relative
        if not path.is_file():
            raise FileNotFoundError(f"gateway source is missing: {relative}")
        digest.update(relative.encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()
