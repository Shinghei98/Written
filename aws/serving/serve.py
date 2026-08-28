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


#: Engine arguments this container asked for and the engine did not have.
#: Reported in `runtime`, never swallowed: a performance property that
#: silently stopped applying is the defect this project keeps paying for, and
#: the attestation is where a claim about the running container belongs.
_dropped_engine_args: list[str] = []

#: The same, for the structured-output params. Kept apart from the engine list
#: because they fail at different moments: an engine argument is wrong once at
#: load, this one is wrong on every request.
_dropped_structured_args: list[str] = []


def _structured_kwargs(cls, kwargs: dict) -> dict:
    """The structured-output arguments this build actually takes.

    `_supported` for `StructuredOutputsParams` — same rule, different class, and
    worth having rather than passing `disable_any_whitespace` blind: it exists
    in vLLM 0.27.1 (verified against the pinned image before this was written)
    and a build without it must still serve rather than raise.
    """
    try:
        import dataclasses  # noqa: PLC0415
        fields = {field.name for field in dataclasses.fields(cls)}
    except Exception:  # noqa: BLE001 - a class that cannot be inspected
        return kwargs      # is one whose arguments are its own business
    kept = {name: value for name, value in kwargs.items() if name in fields}
    dropped = sorted(set(kwargs) - set(kept))
    for name in dropped:
        if name not in _dropped_structured_args:
            _dropped_structured_args.append(name)
    return kept


def _effective_whitespace_guard():
    """Read the guard back off the **loaded engine**, never off what was asked.

    **The distinction is the whole lesson of 2026-08-24.** The request carried
    `disable_any_whitespace=True`, `dropped_structured_args` was empty, and the
    engine was running `StructuredOutputsConfig(disable_any_whitespace=False)`
    the entire time — so every reported signal said the guard was on while the
    overflow count did not move. A declaration cannot verify itself; this is the
    same rule `gateway_revision` follows against the declared image digests.

    `None` means the attribute could not be found, which is reported as unknown
    rather than guessed at. It is never reported as `True` on a failed read.
    """
    for path in (("llm_engine", "vllm_config", "structured_outputs_config"),
                 ("llm_engine", "vllm_config", "decoding_config"),
                 ("llm_engine", "model_config", "structured_outputs_config")):
        node = _engine
        for step in path:
            node = getattr(node, step, None)
            if node is None:
                break
        value = getattr(node, "disable_any_whitespace", None) if node else None
        if value is not None:
            return bool(value)
    return None


def _effective_structured_backend():
    """Which structured-output backend the loaded engine actually resolved to.

    Read back for the same reason the guard is: `auto` is a request, not an
    answer, and the whitespace constraint is honoured by xgrammar and guidance
    alone.
    """
    for path in (("llm_engine", "vllm_config", "structured_outputs_config"),
                 ("llm_engine", "vllm_config", "decoding_config")):
        node = _engine
        for step in path:
            node = getattr(node, step, None)
            if node is None:
                break
        value = getattr(node, "backend", None) if node else None
        if value is not None:
            return str(value)
    return None


def _supported(kwargs: dict) -> dict:
    """The arguments this build of vLLM actually accepts.

    **A wrong keyword is a `TypeError` on a GPU that is already charging**, and
    reacquiring a g6e has measured at six-plus hours. The image build gates
    `language_model_only` for exactly that reason; this is the same check made
    general, so the next argument added is guarded by construction rather than
    by somebody remembering to extend a buildspec. An argument the engine does
    not know is dropped and named — the container still serves, and `runtime`
    says what it is serving without.
    """
    try:
        import dataclasses  # noqa: PLC0415
        from vllm.engine.arg_utils import EngineArgs  # noqa: PLC0415
        fields = {field.name for field in dataclasses.fields(EngineArgs)}
    except Exception:  # noqa: BLE001 - an engine that cannot be inspected
        return kwargs      # is one whose arguments are its own business
    kept = {name: value for name, value in kwargs.items() if name in fields}
    _dropped_engine_args.extend(sorted(set(kwargs) - set(kept)))
    return kept


def engine():
    """Loaded once, from the staged weights, never from a hub."""
    global _engine
    if _engine is None:
        from vllm import LLM  # noqa: PLC0415 - import cost belongs at first use
        _engine = LLM(**_supported(dict(
            model=MODEL_PATH,
            dtype="bfloat16",
            trust_remote_code=False,
            # Bounded by the contract rather than by the model's maximum: the
            # request schema caps the fields and the output budget caps the
            # answer, so a larger window would only buy a longer failure.
            max_model_len=int(os.environ.get("WRITTEN_MAX_MODEL_LEN", "8192")),
            gpu_memory_utilization=float(
                os.environ.get("WRITTEN_GPU_MEMORY_UTILIZATION", "0.90")),
            # **The weights are hybrid; this product is not.** The staged
            # checkpoint declares `Qwen3_5ForConditionalGeneration` and carries a
            # vision tower — `vision_config`, an image token, a video token, a
            # video preprocessor — and nothing here ever sends an image. Loading
            # it would spend GPU memory that the KV cache wants, on a modality
            # the request schema does not admit.
            #
            # Passed unconditionally, which is safe because the image build
            # refuses to push unless `EngineArgs` actually has this field: it is
            # documented as the CLI flag `--language-model-only` and not as a
            # Python keyword, so a wrong guess would be a `TypeError` here, on a
            # GPU that is already charging.
            language_model_only=True,
            # **What makes the fan-out below affordable.** Every item in a
            # batch carries the identical system prompt, rules and few-shots —
            # thousands of tokens — and without caching that prefix is
            # prefilled once per item. Measured need, not a default worth
            # relying on: the engine's own default has changed across versions
            # and this is the one property the batching strategy depends on.
            enable_prefix_caching=True,
            # **How many sequences may be resident at once.** Unset on AWS,
            # where the L40S's KV cache was the binding constraint and the
            # engine's own default was right. An 80 GB card leaves roughly
            # 60 GB after a 9B model in bf16, which holds far more than the
            # default assumes — so the number is stated where the hardware
            # justifies it and omitted (engine default) everywhere else.
            **({"max_num_seqs": int(os.environ["WRITTEN_MAX_NUM_SEQS"])}
               if os.environ.get("WRITTEN_MAX_NUM_SEQS") else {}),
            # **The whitespace guard belongs here, on the engine, and putting it
            # on the request instead cost a whole run.** `StructuredOutputsParams`
            # has a `disable_any_whitespace` field, so passing it per request is
            # accepted and reports nothing dropped — and the engine goes on
            # constructing `StructuredOutputsConfig(disable_any_whitespace=False)`
            # and governs. Measured 2026-08-24: the flag was passed on every
            # request, `dropped_structured_args` was empty, and the overflow
            # count went 147 -> 148. **Accepted is not effective**, which is this
            # codebase's oldest defect wearing new clothes — a call that can fail
            # and a result nobody reads.
            #
            # What it fixes: JSON permits unbounded whitespace between tokens, so
            # a constrained decoder may emit spaces for ever where the model is
            # unsure. All 147 of that run's `output_overflow` rows were spaces —
            # 141 stalled immediately after `"source_field_index":` — and none
            # was a long answer. The token ceiling was never the cause.
            #
            # **The backend has to be named, and that is forced rather than
            # chosen.** `disable_any_whitespace` is supported only by xgrammar
            # and guidance, and `StructuredOutputsConfig` validates that at
            # construction — `backend='auto'` with the flag set is refused by
            # pydantic before the engine starts: *"disable_any_whitespace is
            # only supported for xgrammar and guidance backends"*. So the two
            # settings travel together or neither does.
            #
            # Pinning the backend is a real change and worth stating: `auto` may
            # pick a different one per schema and per release, which for a lane
            # whose whole purpose is to be comparable with the last run is the
            # same objection this project makes to a floating image tag. xgrammar
            # is vLLM's default for JSON schema and is what `auto` was already
            # resolving to here.
            structured_outputs_config={"backend": "xgrammar",
                                       "disable_any_whitespace": True},
        )))
    return _engine


def _version(package: str) -> str | None:
    """A library's version, or None. Absent is reported, never assumed."""
    try:
        import importlib.metadata  # noqa: PLC0415

        return importlib.metadata.version(package)
    except Exception:  # noqa: BLE001
        return None


def _runtime() -> dict:
    """What is actually loaded here, measured rather than declared.

    The gateway used to assemble its whole attestation from Lambda environment
    variables — five strings somebody typed, describing a container the gateway
    had never spoken to. `/ping` answering `{"status": "ok"}` was the other half
    of that: the one process that *could* say what CUDA, torch, vLLM, tokenizer
    and weights were in memory said nothing, so the only available answer was
    the unverified one.

    Everything here is read from the loaded objects. `model_revision` and the
    tokenizer digest come from the staged directory's own manifest, which the
    staging job wrote and checksummed, so they describe the bytes on disk rather
    than a variable that hoped to.
    """
    import hashlib  # noqa: PLC0415
    import pathlib  # noqa: PLC0415

    facts: dict = {}
    try:
        import torch  # noqa: PLC0415
        facts["torch"] = torch.__version__
        facts["cuda"] = getattr(torch.version, "cuda", None)
        facts["gpu"] = (torch.cuda.get_device_name(0)
                        if torch.cuda.is_available() else None)
    except Exception:  # noqa: BLE001 - a missing fact is reported as missing
        facts["torch"] = None

    try:
        import vllm  # noqa: PLC0415
        facts["vllm"] = vllm.__version__
    except Exception:  # noqa: BLE001
        facts["vllm"] = None

    # **What this container asked the engine for and did not get.** Empty is
    # the ordinary answer and precisely the one worth being able to read:
    # prefix caching quietly absent is a throughput regression that nothing
    # else would ever report, and this lane's recurring defect is the call
    # that fails while nobody reads the result.
    facts["dropped_engine_args"] = list(_dropped_engine_args)
    # **What was dropped, and separately, what is actually in force.** Empty
    # here means the *argument* was accepted, which is not the same claim and
    # was measured saying "fine" while the guard was off.
    facts["dropped_structured_args"] = list(_dropped_structured_args)
    # **The one that can contradict us.** Read off the loaded engine: `true` is
    # the guard in force, `false` means the `output_overflow` bucket is back,
    # and `null` means the attribute moved and this needs a new path rather
    # than being trusted either way.
    facts["disable_any_whitespace"] = _effective_whitespace_guard()
    # **The backend beside it, because the guard is only real on two of them.**
    # A reader seeing `disable_any_whitespace: true` under a backend that does
    # not honour it would be reading a claim the engine cannot keep.
    facts["structured_outputs_backend"] = _effective_structured_backend()

    manifest = pathlib.Path(MODEL_PATH) / "manifest.json"
    if manifest.is_file():
        try:
            staged = json.loads(manifest.read_text())
            facts["model_revision"] = staged.get("model_revision")
            facts["model_id"] = staged.get("model_id")
            facts["model_file_count"] = staged.get("file_count")
            facts["model_total_bytes"] = staged.get("total_bytes")
        except Exception:  # noqa: BLE001
            facts["model_revision"] = None

    # **Two tokenizer identities, and only one of them is the pin.**
    # `tokenizer_json_sha256` identifies a file. The runtime manifest identifies
    # the tokenizer *plus* the chat template that wraps every request and the
    # library versions that interpret both — which is what the output budgets
    # were measured against, and what the contract's
    # `tokenizer_manifest_sha256` means. Two deployments can share a
    # `tokenizer.json` and tokenize differently.
    tokenizer_file = pathlib.Path(MODEL_PATH) / "tokenizer.json"
    if tokenizer_file.is_file():
        facts["tokenizer_json_sha256"] = hashlib.sha256(
            tokenizer_file.read_bytes()).hexdigest()

    try:
        import tokenizer_runtime  # noqa: PLC0415 - beside serve.py in the image

        runtime_manifest = tokenizer_runtime.build_manifest(
            MODEL_PATH,
            model_id=facts.get("model_id") or "",
            model_revision=facts.get("model_revision") or "",
            library_versions={"transformers": _version("transformers"),
                              "tokenizers": _version("tokenizers"),
                              "vllm": facts.get("vllm"),
                              "torch": facts.get("torch")})
        facts["tokenizer_runtime_manifest_sha256"] = \
            tokenizer_runtime.manifest_sha256(runtime_manifest)
        facts["tokenizer_runtime_manifest"] = runtime_manifest
    except Exception:  # noqa: BLE001 - reported as missing, never guessed
        facts["tokenizer_runtime_manifest_sha256"] = None

    facts["serving_image_digest"] = os.environ.get("WRITTEN_SERVING_IMAGE_DIGEST")
    facts["max_model_len"] = int(os.environ.get("WRITTEN_MAX_MODEL_LEN", "8192"))
    return facts


def _structured_params(schema: dict, max_tokens: int):
    """Schema-constrained sampling, under whichever name this build uses.

    **The API was renamed and the old one is gone.** `GuidedDecodingParams` and
    `guided_decoding=` are what vLLM 0.11 exposed; current builds — which is what
    a Qwen3.5-capable engine has to be — use `StructuredOutputsParams` and
    `structured_outputs=`. Importing the old name on a new build raises
    `ImportError` at the first inference, on a GPU that is already charging, and
    it reads as a broken container rather than a stale call.

    The modern name is tried first and the old one is a fallback rather than the
    other way round, because the deployment this is being built for is the modern
    one; the fallback exists so the container is not tied to a single engine
    release, not because either is preferred.

    **Never unconstrained.** If neither is available this raises: an engine that
    cannot be constrained returns prose, which fails acceptance for a reason that
    looks like a bad model.

    **Whitespace is forbidden, and that is not tidiness — it is the whole of the
    `output_overflow` bucket.** JSON permits arbitrary whitespace between tokens,
    so a grammar-constrained decoder may legally emit spaces for ever; the model
    reaches a point it is unsure of and drifts into that state instead of
    committing. Measured on the v18 run, 2026-08-24: **147 of 4,187 production
    rows finished on `length`, and all 147 were whitespace loops — none was a
    genuinely long answer.** 141 stalled at the same place, immediately after
    `"source_field_index":`, the one nullable integer in the schema; the rest
    stalled after an unescaped quote inside a title that contained one.

    **So the token ceiling was never the cause, and raising it never was the
    cure.** `WRITTEN_MAX_OUTPUT_TOKENS` went 800 -> 2400 for "long classical
    titles"; what that actually bought was three times as many spaces per stuck
    row. `disable_any_whitespace` removes the state from the grammar, which is
    the only fix that ends the loop rather than lengthening it.

    **Filtered against the build, for the reason `_supported` gives.** A keyword
    this engine does not have is a `TypeError` at the first inference, on a GPU
    that is already charging — and unlike the engine arguments, this one is
    reached per request rather than once at load. What is dropped is named in
    `runtime`, because a constraint that silently stopped applying is this lane's
    recurring defect.
    """
    from vllm import SamplingParams  # noqa: PLC0415

    try:
        from vllm.sampling_params import StructuredOutputsParams  # noqa: PLC0415

        return SamplingParams(
            temperature=0, max_tokens=max_tokens,
            structured_outputs=StructuredOutputsParams(**_structured_kwargs(
                StructuredOutputsParams,
                {"json": schema, "disable_any_whitespace": True})))
    except ImportError:
        pass

    try:
        from vllm.sampling_params import GuidedDecodingParams  # noqa: PLC0415

        return SamplingParams(
            temperature=0, max_tokens=max_tokens,
            guided_decoding=GuidedDecodingParams(json=schema))
    except ImportError as failure:
        raise RuntimeError(
            "this vLLM build exposes neither StructuredOutputsParams nor "
            "GuidedDecodingParams; it cannot be constrained to the schema and "
            "must not be asked to extract") from failure


def read_body(headers, rfile) -> bytes:
    """The request body, under either framing SageMaker uses.

    **Async delivery is chunked, and `Content-Length` reads zero of it.** A
    synchronous `invoke-endpoint` arrives with a length header; the async
    channel — which is the only channel this endpoint serves — delivers the
    payload with `Transfer-Encoding: chunked` and no length. The first version
    read the header, got 0, parsed `{}` and refused its own valid request as
    `response_format.schema is required` — on a GPU that had finally booted,
    with the whole engine healthy behind it. Reproduced locally with one
    chunked curl, which is how this must be tested forever after.

    A module function rather than a method so a build gate and a unit test can
    feed it a fake stream without standing up a server.
    """
    if "chunked" in (headers.get("transfer-encoding") or "").lower():
        chunks = []
        while True:
            size_line = rfile.readline()
            if not size_line:
                break  # a truncated stream yields what arrived
            size = int(size_line.split(b";")[0].strip() or b"0", 16)
            if size == 0:
                rfile.readline()  # the CRLF closing the terminal chunk
                break
            chunks.append(rfile.read(size))
            rfile.readline()  # the CRLF closing this chunk
        return b"".join(chunks)
    length = int(headers.get("content-length") or 0)
    return rfile.read(length)


def _prompts(payload: dict) -> list[str]:
    """One prompt per item, which is what lets the GPU batch the work.

    **A batch was one prompt until 2026-08-21, and that was the whole of the
    throughput problem.** `generate([prompt])` on an eight-item document is a
    single sequence: one enormous structured JSON decoded token by token, with
    the GPU running one stream and the other slots idle. Measured 4.3 s an
    item mean, 9.5 s worst — and a sweep of a thousand terms took hours.

    Split per item, the engine does what it is built for: N sequences,
    continuously batched, each emitting one small envelope, sharing a
    prefix-cached system prompt. The document each prompt carries is the
    original with `items` narrowed to one, **keeping the item's true
    `item_index`** — so the answers merge without renumbering and the
    gateway's coverage check (every requested index answered exactly once)
    still means what it meant.

    A one-item document is passed through unchanged rather than rebuilt, so
    the single-item path — every probe, the release gate — is byte-identical
    to what it was.
    """
    document = payload.get("input") or {}
    items = document.get("items")
    if not isinstance(items, list) or len(items) < 2:
        return [_prompt(payload)]
    return [_prompt({**payload, "input": {**document, "items": [item]}})
            for item in items]


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
    # **The definitions come before the rules, and before 2026-08-24 there were
    # none.** The families and roots reached the model only as an xgrammar
    # constraint on decoding — a grammar over tokens, never text — so nothing
    # ever told it what a `franchise` is, or that a title matching no definition
    # should yield no terms. Order is deliberate: the governing rule first
    # because it licenses refusing, then what the roots and families *are*,
    # then how to say "present but not a term", and only then the imperative
    # rules, which are patches over whatever the definitions leave open.
    system = "\n".join(
        part for part in (
            instructions.get("system_role"),
            instructions.get("governing_rule"),
            instructions.get("cardinal_definitions"),
            instructions.get("family_definitions"),
            instructions.get("refusal_role_definitions"),
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


def _merge(outputs) -> tuple[str, str]:
    """N single-item envelopes into the one envelope the contract defines.

    **Truncation is reported, never hidden.** If any sequence stopped on
    `length` the merged answer says so, because the gateway refuses a
    truncated answer outright and a batch where one item ran to the cap is a
    truncated answer. An unparseable sequence contributes no item: the
    gateway's coverage check then refuses the batch by name (`missing_item`)
    rather than accepting a silently shorter one — the same refusal a model
    that skipped an item has always produced.
    """
    merged: list = []
    version = None
    finish = "stop"
    for output in outputs:
        if output.finish_reason == "length":
            finish = "length"
        try:
            envelope = json.loads(output.text)
        except (ValueError, TypeError):
            continue
        if not isinstance(envelope, dict):
            continue
        version = version or envelope.get("schema_version")
        answered = envelope.get("items")
        if isinstance(answered, list):
            merged.extend(answered)
    body = {"schema_version": version, "items": merged}
    return json.dumps(body, ensure_ascii=False), finish


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
        # **Healthy says what it is healthy with.** An operator, and the
        # gateway's attestation, need the loaded runtime rather than the word
        # "ok" — which is true of a container serving the wrong weights.
        self._reply(200, {"status": "ok", "runtime": _runtime()})

    def do_POST(self):  # noqa: N802
        if self.path != "/invocations":
            return self._reply(404, {})
        payload = json.loads(read_body(self.headers, self.rfile) or b"{}")

        # **Refused rather than answered unconstrained.** The gateway sends the
        # schema; an engine asked to extract without one returns prose, which
        # then fails acceptance looking like a bad model rather than a request
        # that never carried its contract. Guessing a default schema here would
        # be this container deciding what it may emit, which is the gateway's
        # decision and is attested.
        schema = payload.get("response_format", {}).get("schema")
        if not schema:
            return self._reply(400, {"error": "response_format.schema is required"})

        params = _structured_params(
            schema, int(payload.get("max_output_tokens", 4096)))
        prompts = _prompts(payload)
        completions = engine().generate(prompts, params)
        outputs = [completion.outputs[0] for completion in completions]

        if len(outputs) == 1:
            content = outputs[0].text
            finish = outputs[0].finish_reason
        else:
            content, finish = _merge(outputs)

        self._reply(200, {
            "choices": [{
                "finish_reason": finish,
                "message": {"content": content},
            }],
            "usage": {"completion_tokens":
                      sum(len(output.token_ids) for output in outputs)},
            # **Travels with the answer, not only with the health check.** An
            # attestation taken at some earlier moment describes the container
            # that was running then; this one describes the container that
            # produced *this* answer, which is the claim that matters when the
            # answer becomes something said about a person.
            "runtime": _runtime(),
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
