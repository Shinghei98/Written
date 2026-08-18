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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL_PATH = os.environ.get("MODEL_PATH", "/opt/ml/model")
_engine = None


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


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # noqa: A003 - silence is the point
        """No access log. A request is somebody's title."""

    def do_GET(self):  # noqa: N802
        if self.path == "/ping":
            self._reply(200, {"status": "ok"})
        else:
            self._reply(404, {})

    def do_POST(self):  # noqa: N802
        if self.path != "/invocations":
            return self._reply(404, {})
        length = int(self.headers.get("content-length") or 0)
        payload = json.loads(self.rfile.read(length) or b"{}")

        from vllm import SamplingParams  # noqa: PLC0415
        from vllm.sampling_params import GuidedDecodingParams  # noqa: PLC0415

        schema = payload.get("response_format", {}).get("schema")
        params = SamplingParams(
            temperature=0,
            max_tokens=int(payload.get("max_output_tokens", 4096)),
            guided_decoding=GuidedDecodingParams(json=schema) if schema else None,
        )
        prompt = json.dumps(payload.get("input", {}), ensure_ascii=False)
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


if __name__ == "__main__":
    ThreadingHTTPServer(("", 8080), Handler).serve_forever()
