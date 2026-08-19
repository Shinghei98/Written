"""serve.py must read the body SageMaker actually sends.

**Async delivery is chunked.** The engine's first fully healthy boot answered
its own attestation probe with `response_format.schema is required`, because
`do_POST` read `Content-Length` — which async delivery does not send — got
zero bytes, and parsed `{}`. Every production call through the lane would have
400'd the same way; the probe found it first, which is the probe's job.

`read_body` is a module function precisely so this file and the image gate can
feed it a fake stream without standing up a server.
"""
from __future__ import annotations

import importlib.util
import io
import pathlib
import sys

import pytest

REPOSITORY = pathlib.Path(__file__).resolve().parents[2]


@pytest.fixture(scope="module")
def serve():
    spec = importlib.util.spec_from_file_location(
        "serve_under_test", REPOSITORY / "aws" / "serving" / "serve.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class Headers(dict):
    """Case-insensitive get, as http.client's message object behaves."""

    def get(self, key, default=None):
        return super().get(key.lower(), default)


def chunked(data: bytes, size: int = 7) -> bytes:
    out = b""
    for i in range(0, len(data), size):
        piece = data[i:i + size]
        out += hex(len(piece))[2:].encode() + b"\r\n" + piece + b"\r\n"
    return out + b"0\r\n\r\n"


def test_chunked_body_is_read_whole(serve):
    body = b'{"response_format": {"schema": {"type": "object"}}}'
    got = serve.read_body(Headers({"transfer-encoding": "chunked"}),
                          io.BytesIO(chunked(body)))
    assert got == body


def test_content_length_still_works(serve):
    """The synchronous channel keeps its framing; the fix must not trade one for the other."""
    body = b'{"a": 1}'
    got = serve.read_body(Headers({"content-length": str(len(body))}),
                          io.BytesIO(body))
    assert got == body


def test_chunk_size_lines_with_extensions_parse(serve):
    """`7;ext=1` is legal chunk framing; the size is the part before the semicolon."""
    body = b"abcdefg"
    stream = io.BytesIO(b"7;ext=1\r\n" + body + b"\r\n0\r\n\r\n")
    assert serve.read_body(Headers({"transfer-encoding": "chunked"}), stream) == body


def test_an_empty_chunked_body_is_still_empty(serve):
    """The 400 for a genuinely schema-less request must survive the fix."""
    got = serve.read_body(Headers({"transfer-encoding": "chunked"}),
                          io.BytesIO(b"0\r\n\r\n"))
    assert got == b""


def test_a_truncated_stream_returns_what_arrived(serve):
    """A dropped connection must not hang the handler waiting on bytes."""
    stream = io.BytesIO(b"7\r\nabc")  # promised 7, delivered 3, then EOF
    got = serve.read_body(Headers({"transfer-encoding": "chunked"}), stream)
    assert got == b"abc"
