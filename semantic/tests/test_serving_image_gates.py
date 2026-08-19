"""What the serving image build must keep, pinned where a diff can see it.

The build's gates run in CodeBuild, on a machine nobody watches, and the thing
they protect against is a wrong engine reaching a GPU that is already charging.
That makes them exactly the kind of check that gets quietly relaxed — a gate
that has never refused anything looks like ceremony.

So the properties are asserted here too, offline, against the template and
`serve.py` as written. **None of these replaces its gate**: the gate answers
about the built image, and this answers about the file that builds it.
"""
from __future__ import annotations

import pathlib
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
BASE_STACK = REPO / "aws" / "serving" / "base-stack.yaml"
SERVE = REPO / "aws" / "serving" / "serve.py"

#: The architecture the staged checkpoint declares in its own `config.json`
#: (read from S3, 2026-08-18). The build requires this exact string, because a
#: build supporting Qwen3 and not Qwen3.5 passes any looser test.
DECLARED_ARCHITECTURE = "Qwen3_5ForConditionalGeneration"


class ServingImageGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.stack = BASE_STACK.read_text(encoding="utf-8")
        cls.serve = SERVE.read_text(encoding="utf-8")

    def test_the_exact_architecture_is_required(self) -> None:
        self.assertIn(
            f'required = "{DECLARED_ARCHITECTURE}"', self.stack,
            "the build must require the architecture the checkpoint declares; "
            "a prefix test admits an engine that cannot load these weights")

    def test_the_version_is_not_the_docker_tag_of_a_local_version(self) -> None:
        """`+` is not a legal Docker tag character.

        The tag is built from `VLLM_VERSION`, so a value like `0.27.1+cu129`
        fails at `docker build -t` before any gate is reached. The CUDA variant
        is named by the wheel URL instead.
        """
        self.assertIn('TAG="vllm-${VLLM_VERSION}-${COMMIT}"', self.stack)
        self.assertIn("VLLM_WHEEL_URL", self.stack)
        self.assertIn("VLLM_WHEEL_SHA256", self.stack)

    def test_the_wheel_is_verified_before_it_is_installed(self) -> None:
        """A URL names a location; only the hash names the artifact."""
        self.assertIn("sha256sum -c -", self.stack)
        self.assertNotIn('pip install --no-cache-dir "vllm==${VLLM_VERSION}"',
                         self.stack,
                         "installing by version resolves against PyPI, which "
                         "cannot serve the pinned +cu129 wheel at all")

    def test_the_entrypoint_is_the_cuda_compat_shim(self) -> None:
        """A CUDA 12.9 engine on a driver-550 host needs forward compatibility.

        `ENTRYPOINT ["python3", ...]` has nowhere to set `LD_LIBRARY_PATH`, so
        the shim is not a style choice — it is the only place the decision can
        be made, and it has to be made at boot because the host driver is not
        knowable at build time.
        """
        self.assertIn('ENTRYPOINT ["/opt/entrypoint.sh"]', self.stack)
        self.assertNotIn('ENTRYPOINT ["python3", "/opt/serve.py"]', self.stack)
        self.assertIn("/usr/local/cuda/compat", self.stack)

    def test_the_gateway_build_asks_nothing_about_vllm(self) -> None:
        """It has no engine and sets no VLLM_VERSION.

        A refusal there failed every gateway build for a reason that had nothing
        to do with the gateway, which is how the check was found.
        """
        gateway = self.stack.split("BuildGatewayImage:", 1)[1]
        self.assertNotIn("VLLM_VERSION is unset", gateway)
        self.assertNotIn(DECLARED_ARCHITECTURE, gateway)

    def test_serve_asks_for_the_language_model_only(self) -> None:
        """The checkpoint is hybrid and this product sends only text."""
        self.assertIn("language_model_only=True", self.serve)

    def test_serve_prefers_the_modern_structured_output_api(self) -> None:
        """`GuidedDecodingParams` is the fallback, not the request.

        An engine new enough to load Qwen3.5 exposes `StructuredOutputsParams`;
        reaching for the old name first would raise on the first inference.
        """
        # **The imports, not any mention.** The docstring explains the rename
        # and so names the old API first; a test reading raw offsets measures
        # the prose and fails on a correct file, which is what it did.
        modern = self.serve.index(
            "from vllm.sampling_params import StructuredOutputsParams")
        legacy = self.serve.index(
            "from vllm.sampling_params import GuidedDecodingParams")
        self.assertLess(modern, legacy)

    def test_the_serving_gates_invoke_python3(self) -> None:
        """The two images do not agree about what `python` is.

        The serving base installs `python3` and `python3-pip` and creates no
        `python` alias; the gateway image is a Lambda python base and does have
        one. So the same `--entrypoint python` is right in one build and, in the
        other, `exec: "python": executable file not found` — which is what the
        first real run of these gates reported, after the image had been built.

        Asserted per build rather than globally, because the difference is real
        and a rule that forced them to match would be wrong about the gateway.
        """
        serving, gateway = self.stack.split("BuildGatewayImage:", 1)
        for line in serving.splitlines():
            if "--entrypoint python" in line:
                self.assertIn(
                    "--entrypoint python3", line,
                    "the serving image has no `python`, only `python3`: " + line.strip())
        self.assertIn("--entrypoint python ", gateway,
                      "the gateway image does have `python`; if that changed, "
                      "this test is the wrong thing to fix")

    def test_the_image_carries_tritons_jit_toolchain(self) -> None:
        """Triton compiles C at engine start, not at build.

        The first image to reach a GPU loaded all four weight shards in two
        seconds and then died on "Failed to find C compiler" — a runtime
        dependency that looks like a build tool. The compiler install and its
        gate must both survive.
        """
        for needed in ("gcc", "python3-dev", "ninja-build"):
            self.assertIn(needed, self.stack,
                          f"{needed} left the image; triton fails at engine "
                          f"start, after the weights have loaded")
        self.assertIn("jit toolchain present", self.stack,
                      "the gate proving the toolchain is gone")

    def test_the_dead_dockerfile_is_gone(self) -> None:
        """It was referenced by nothing and omitted `tokenizer_runtime.py`.

        `serve.py` imports that module, so an image built from it would report
        a null manifest — which the gateway reads as drift and refuses. Two
        Dockerfiles that can disagree is the defect; staleness was the symptom.
        """
        self.assertFalse((REPO / "aws" / "serving" / "Dockerfile").exists())


if __name__ == "__main__":
    unittest.main()
