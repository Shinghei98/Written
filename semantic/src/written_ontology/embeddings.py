from __future__ import annotations

from collections.abc import Sequence
from typing import Protocol

from .normalize import hashing_ngram_vector


class EmbeddingBackend(Protocol):
    """Candidate-generation interface; vectors never constitute entailment."""

    model_id: str

    def encode(self, texts: Sequence[str]) -> tuple[tuple[float, ...], ...]: ...


class HashingNgramEmbedder:
    """Deterministic dependency-free backend for tests and lexical neighbors."""

    model_id = "hashing-ngram-384:v1"

    def encode(self, texts: Sequence[str]) -> tuple[tuple[float, ...], ...]:
        return tuple(hashing_ngram_vector(text) for text in texts)


class SentenceTransformerEmbedder:
    """Optional multilingual semantic backend loaded only when requested."""

    def __init__(
        self,
        model_id: str = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2",
    ) -> None:
        self.model_id = model_id
        try:
            from sentence_transformers import SentenceTransformer
        except ImportError as error:
            raise RuntimeError(
                "install the semantic extra: pip install -e '.[semantic]'"
            ) from error
        self._model = SentenceTransformer(model_id)

    def encode(self, texts: Sequence[str]) -> tuple[tuple[float, ...], ...]:
        vectors = self._model.encode(
            list(texts),
            normalize_embeddings=True,
            convert_to_numpy=True,
        )
        return tuple(tuple(float(value) for value in vector) for vector in vectors)
