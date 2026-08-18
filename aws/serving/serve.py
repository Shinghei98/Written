"""The serving shim: /ping and /invocations over one in-process vLLM engine.

SageMaker speaks to a container on 8080 through exactly two paths whatever the
engine is, so this is the adapter and nothing more. It makes no decisions the
gateway has not already made: the request arrives having passed
`mention_extract_request_v1`, and the response is validated against
`mention_extract_v2` by the caller, not here. A serving container that validated
its own output would be marking its own homework.

**Structured output is enforced by the engine**, with the schema handed in per
request. `enable_thinking` is false, matching the tokenizer manifest, and the
context is bounded by the contract rather than by whatever the model will accept.
"""
from __future__ import annotations

import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL_PATH = os.environ.get("MODEL_PATH", "/opt/ml/model")
_engine = None
_load_error: BaseException | None = None
_loaded = threading.Event()


def engine():
    """Loaded once, from the staged weights, never from a hub."""
    global _engine
    if _engine is None:
        from vllm import LLM  # noqa: PLC0415 - import cost belongs at first use
        _engine = LLM(
            model=MODEL_PATH,
            dtype="bfloat16",
            trust_remote_code=False,
            # Bounded by the contract rather than by the model's maximum: the
            # request schema caps the fields and the output budget caps the
            # answer, so a larger window would only buy a longer failure.
            max_model_len=int(os.environ.get("WRITTEN_MAX_MODEL_LEN", "8192")),
            gpu_memory_utilization=float(
                os.environ.get("WRITTEN_GPU_MEMORY_UTILIZATION", "0.90")),
        )
    return _engine


def _prompt(payload: dict) -> str:
    """The chat template, applied, with the instructions the contract carries.

    Two things were wrong and both were silent. `generate()` on a bare string
    **bypasses the chat template entirely**, so `enable_thinking: false` — a
    template keyword, not a sampling parameter — was read by nothing and the
    model was free to emit reasoning into a schema-shaped answer. And the prompt
    was the request document alone: no role, no rules, no worked example. The
    contract named a prompt version the whole time; nothing sent one.

    A tokenizer with no `enable_thinking` keyword is not an error — most have
    none — so it is passed only when the template accepts it, and its absence
    is not silently read as false.
    """
    instructions = payload.get("instructions") or {}
    system = "\n".join(
        part for part in (
            instructions.get("system_role"),
            instructions.get("system_rules"),
            instructions.get("aboutness_example"),
        ) if part
    )
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({
        "role": "user",
        "content": json.dumps(payload.get("input", {}), ensure_ascii=False),
    })

    tokenizer = engine().get_tokenizer()
    kwargs = {"tokenize": False, "add_generation_prompt": True}
    if payload.get("enable_thinking") is not None:
        try:
            return tokenizer.apply_chat_template(
                messages, enable_thinking=bool(payload["enable_thinking"]), **kwargs)
        except TypeError:
            # The template does not take the keyword. Falling through is right;
            # pretending it was applied is not.
            pass
    return tokenizer.apply_chat_template(messages, **kwargs)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # noqa: A003 - silence is the point
        """No access log. A request is somebody's title."""

    def do_GET(self):  # noqa: N802
        if self.path != "/ping":
            return self._reply(404, {})
        # **Healthy means loaded, and it did not.** This answered 200 the
        # instant the socket was up while the engine was built lazily in the
        # first POST, so SageMaker declared the container ready and routed a
        # request into a 19 GB model load. AWS keeps routing to anything
        # answering 200; the health check is the only thing that can say wait.
        #
        # A failed load stays unhealthy for the same reason: a container that
        # cannot serve must not be sent work, and reporting the failure here is
        # what makes it visible as a failure rather than as slowness.
        if _load_error is not None:
            return self._reply(503, {"status": "failed",
                                     "error": type(_load_error).__name__})
        if not _loaded.is_set():
            return self._reply(503, {"status": "loading"})
        self._reply(200, {"status": "ok"})

    def do_POST(self):  # noqa: N802
        if self.path != "/invocations":
            return self._reply(404, {})
        length = int(self.headers.get("content-length") or 0)
        payload = json.loads(self.rfile.read(length) or b"{}")

        from vllm import SamplingParams  # noqa: PLC0415
        from vllm.sampling_params import GuidedDecodingParams  # noqa: PLC0415

        # **Refused rather than answered unconstrained.** The gateway sends the
        # schema; an engine asked to extract without one returns prose, which
        # then fails acceptance looking like a bad model rather than a request
        # that never carried its contract. Guessing a default schema here would
        # be this container deciding what it may emit, which is the gateway's
        # decision and is attested.
        schema = payload.get("response_format", {}).get("schema")
        if not schema:
            return self._reply(400, {"error": "response_format.schema is required"})

        params = SamplingParams(
            temperature=0,
            max_tokens=int(payload.get("max_output_tokens", 4096)),
            guided_decoding=GuidedDecodingParams(json=schema),
        )
        prompt = _prompt(payload)
        completions = engine().generate([prompt], params)
        output = completions[0].outputs[0]
        self._reply(200, {
            "choices": [{
                "finish_reason": output.finish_reason,
                "message": {"content": output.text},
            }],
            "usage": {"completion_tokens": len(output.token_ids)},
        })

    def _reply(self, code: int, body: dict):
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


def _load_in_background() -> None:
    """Start loading immediately, and record a failure rather than raising.

    The load happens off the serving thread so /ping can answer at all while it
    runs — an unanswered health check is indistinguishable from a dead
    container, and would be treated as one.
    """
    global _load_error
    try:
        engine()
    except BaseException as failure:  # noqa: BLE001 - the type, never the message
        _load_error = failure
    else:
        _loaded.set()


if __name__ == "__main__":
    threading.Thread(target=_load_in_background, daemon=True).start()
    ThreadingHTTPServer(("", 8080), Handler).serve_forever()
