"""The tokenizer runtime manifest: one definition, used to make it and to check it.

**`sha256(tokenizer.json)` is not this.** A tokenizer file identifies a file. What
the output budgets were measured against is a *runtime* — the tokenizer files
together with the chat template that wraps every request and the library
versions that interpret both. Two deployments can hold an identical
`tokenizer.json` and tokenize differently because one applies a different chat
template or a different `tokenizers` build; a pin on the file alone would call
those the same runtime and they are not.

So the manifest names all of it, is serialised canonically, and the digest of
that serialisation is what the contract pins as `tokenizer_manifest_sha256` and
what `release_manifests.tokenizer_runtime_manifest_sha256` stores.

## One definition, two callers

This module is fetched by both the staging job, which writes the manifest beside
the weights, and the serving container, which recomputes it from what it actually
loaded. **A second implementation would be the whole defect back again**: the
generator and the verifier agreeing because they were written by the same person
on the same afternoon rather than because they compute the same function.

## Canonical means canonical

`sort_keys=True`, no whitespace, UTF-8, and `ensure_ascii=False` so a template
containing non-Latin text hashes as the bytes it is rather than as escapes. A
manifest whose digest depends on key order would change without the runtime
changing, which is the same class of lie as a digest that does not change when it
does.
"""
from __future__ import annotations

import hashlib
import json
import pathlib
from typing import Any

MANIFEST_VERSION = "tokenizer_runtime_v1"

#: The files that decide how text becomes tokens. `chat_template.jinja` is here
#: because `enable_thinking` and the message wrapper are applied from it, and a
#: budget measured under one template does not hold under another. Absent files
#: are recorded as absent rather than skipped: a runtime with no merges file is a
#: different runtime from one that has it.
TOKENIZER_FILES = (
    "tokenizer.json",
    "tokenizer_config.json",
    "vocab.json",
    "merges.txt",
    "chat_template.jinja",
    "special_tokens_map.json",
    "added_tokens.json",
)


def _digest_of(path: pathlib.Path) -> str | None:
    if not path.is_file():
        return None
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build_manifest(model_dir: str | pathlib.Path, *, model_id: str,
                   model_revision: str,
                   library_versions: dict[str, str | None]) -> dict[str, Any]:
    """The manifest, from files on disk and versions the caller measured.

    `library_versions` is passed in rather than imported here because the two
    callers are in different places: the staging job has no vLLM installed and
    records the versions the image pins, while the serving container reports the
    versions it actually imported. Both describe the same runtime; only one of
    them can measure it.
    """
    root = pathlib.Path(model_dir)
    return {
        "manifest_version": MANIFEST_VERSION,
        "model_id": model_id,
        "model_revision": model_revision,
        "files": {name: _digest_of(root / name) for name in TOKENIZER_FILES},
        "library_versions": {
            name: library_versions.get(name)
            for name in ("transformers", "tokenizers", "vllm", "torch")
        },
    }


def canonical_bytes(manifest: dict[str, Any]) -> bytes:
    """The one serialisation the digest is taken over."""
    return json.dumps(manifest, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False).encode("utf-8")


def manifest_sha256(manifest: dict[str, Any]) -> str:
    return hashlib.sha256(canonical_bytes(manifest)).hexdigest()
