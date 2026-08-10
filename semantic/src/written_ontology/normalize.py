from __future__ import annotations

import hashlib
import math
import re
import unicodedata
from collections.abc import Iterable


_SPACE_RE = re.compile(r"\s+")


def normalize_text(value: str) -> str:
    """Unicode-aware normalization without erasing non-Latin scripts."""
    value = unicodedata.normalize("NFKC", value).casefold().strip()
    chars: list[str] = []
    for char in value:
        category = unicodedata.category(char)
        if category[0] in {"L", "N"}:
            chars.append(char)
        elif category[0] in {"Z", "P", "S"}:
            chars.append(" ")
    return _SPACE_RE.sub(" ", "".join(chars)).strip()


def accent_fold(value: str) -> str:
    decomposed = unicodedata.normalize("NFKD", normalize_text(value))
    return "".join(char for char in decomposed if not unicodedata.combining(char))


def stable_hash(*values: object) -> str:
    payload = "\x1f".join("" if value is None else str(value) for value in values)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def parse_semicolon_kv(value: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for part in value.split(";") if value else ():
        if "=" not in part:
            continue
        key, item_value = part.split("=", 1)
        key = key.strip()
        if key:
            result[key] = item_value.strip()
    return result


def hashing_ngram_vector(text: str, dimensions: int = 384) -> tuple[float, ...]:
    """Deterministic offline candidate-generation vector.

    This representation is useful for tests and lexical neighborhood lookup.
    It is not treated as semantic entailment.
    """
    normalized = f"  {accent_fold(text)}  "
    vector = [0.0] * dimensions
    for size in (2, 3, 4):
        for start in range(max(0, len(normalized) - size + 1)):
            gram = normalized[start : start + size]
            digest = hashlib.blake2b(gram.encode("utf-8"), digest_size=8).digest()
            index = int.from_bytes(digest, "big") % dimensions
            sign = 1.0 if digest[0] & 1 else -1.0
            vector[index] += sign
    norm = math.sqrt(sum(value * value for value in vector))
    if norm == 0:
        return tuple(vector)
    return tuple(value / norm for value in vector)


def cosine(left: Iterable[float], right: Iterable[float]) -> float:
    return sum(a * b for a, b in zip(left, right, strict=True))

