"""The gateway process.

`gateway_http.application` is the WSGI app; this is what runs it and what tells
it which deployment it is. Nothing here decides a rule — the point of a thin
entrypoint is that reading it tells you nothing you could get wrong elsewhere.

**A real WSGI server if one is installed, and a loud fallback if not.**
`wsgiref` is single-threaded and is not a production server; it is enough to
prove the routes answer over a real socket, which is what `off` needs to
demonstrate before anything else happens.
"""
from __future__ import annotations

import functools
import json
import os
import sys

from written_ontology import gateway, gateway_http
from written_ontology.semantic_contract import load as load_contract


def _measured_gateway_revision() -> str:
    """Hash the gateway sources this process actually loaded.

    `written_ontology` and the flat Lambda modules sit at known places inside the
    image, so the same function that compiles the contract's expectation can be
    pointed at them. If a file is missing the answer is empty rather than a
    guess, and an empty answer cannot match the contract.
    """
    import pathlib  # noqa: PLC0415

    from written_ontology.gateway_revision import gateway_revision  # noqa: PLC0415

    root = pathlib.Path(os.environ.get("LAMBDA_TASK_ROOT", "")) or pathlib.Path(".")
    # In the image the layout is flattened: aws/gateway/*.py land beside the
    # package. A staging directory mirrors the repository, so both are tried.
    for candidate in (pathlib.Path(__file__).resolve().parents[2], root):
        try:
            return gateway_revision(candidate)
        except (FileNotFoundError, IndexError):
            continue
    return ""


def build_deployment() -> gateway.Deployment | None:
    """What this process actually loaded.

    Read from the environment rather than the contract, deliberately: a gateway
    that answered with the contract's own expectations would be attesting to
    itself, and `attestation()` compares the two.
    """
    required = ("WRITTEN_GATEWAY_IMAGE_DIGEST", "WRITTEN_SERVING_IMAGE_DIGEST",
                "WRITTEN_TOKENIZER_SHA256", "WRITTEN_MODEL_ID",
                "WRITTEN_MODEL_REVISION")
    # **These are declarations about a container this process has never spoken
    # to.** They are kept because a release has to record them somewhere, and
    # they are no longer the whole of the attestation: `gateway_revision` below
    # is measured from the files actually loaded here, and the serving facts are
    # re-checked against the runtime block the container sends with each answer.
    if not all(os.environ.get(name) for name in required):
        # None is honest: nothing is attested. `extract` refuses on it, and
        # `attestation` reports `loaded: null` rather than inventing a value.
        return None
    contract = load_contract()
    expected = contract.attestation()
    return gateway.Deployment(
        model_id=os.environ["WRITTEN_MODEL_ID"],
        model_revision=os.environ["WRITTEN_MODEL_REVISION"],
        tokenizer_sha256=os.environ["WRITTEN_TOKENIZER_SHA256"],
        # Measured, not declared: a digest over the gateway sources in this
        # image. The contract carries the same hash, so a gateway running code
        # the contract does not describe fails attestation instead of reporting
        # a variable back.
        gateway_revision=_measured_gateway_revision(),
        gateway_image_digest=os.environ["WRITTEN_GATEWAY_IMAGE_DIGEST"],
        serving_image_digest=os.environ["WRITTEN_SERVING_IMAGE_DIGEST"],
        # The prompt, grammar and schemas come from the contract this process
        # loaded, because those *are* what it loaded.
        prompt_version=expected["prompt_version"],
        grammar_version=expected["grammar_version"],
        output_schema_sha256=expected["schema_sha256"],
        contract_sha256=expected["compiled_contract_sha256"],
        environment=os.environ.get("WRITTEN_ENVIRONMENT", "unknown"),
    )


def build_transport():
    """None until an endpoint is configured, which is correct while the lane is off."""
    endpoint = os.environ.get("WRITTEN_MODEL_ENDPOINT")
    if not endpoint:
        return None
    return gateway_http.HttpModelTransport(
        endpoint, api_key=os.environ.get("WRITTEN_MODEL_API_KEY"))


def make_app():
    deployment = build_deployment()
    transport = build_transport()
    breaker = gateway.CircuitBreaker()
    return functools.partial(gateway_http.application, deployment=deployment,
                             transport=transport, breaker=breaker)


def main(argv: list[str]) -> int:
    port = int(os.environ.get("PORT", "8080"))
    app = make_app()
    contract = load_contract()
    print(json.dumps({
        "listening": port,
        "model_lane_mode": contract.model_lane_mode,
        "extraction_enabled": contract.model_may_be_called,
        "deployment_attested": build_deployment() is not None,
        "transport_configured": build_transport() is not None,
    }), file=sys.stderr)

    from wsgiref.simple_server import make_server
    with make_server("", port, app) as httpd:
        print("wsgiref is not a production server; this is enough to answer "
              "health and attestation and to refuse extraction while the lane "
              "is off", file=sys.stderr)
        httpd.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
