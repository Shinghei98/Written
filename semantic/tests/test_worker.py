from __future__ import annotations

import unittest

from written_ontology.repository import WorkerJob
from written_ontology.worker import SemanticWorker


class FakeQueue:
    def __init__(self, job: WorkerJob | None) -> None:
        self.job = job
        self.succeeded: list[tuple[str, dict[str, object]]] = []
        self.failed: list[tuple[str, str, bool]] = []

    def claim(self) -> WorkerJob | None:
        job, self.job = self.job, None
        return job

    def succeed(
        self,
        job_id: str,
        result: dict[str, object],
        *,
        lease_token: str,
    ) -> None:
        self.assert_lease(lease_token)
        self.succeeded.append((job_id, result))

    def fail(
        self,
        job_id: str,
        error_code: str,
        retry: bool = True,
        *,
        lease_token: str,
    ) -> None:
        self.assert_lease(lease_token)
        self.failed.append((job_id, error_code, retry))

    @staticmethod
    def assert_lease(lease_token: str) -> None:
        if lease_token != "lease-fixture":
            raise AssertionError("worker did not preserve the per-claim lease token")


def job(job_type: str = "map_observation") -> WorkerJob:
    return WorkerJob(
        id="00000000-0000-0000-0000-000000000001",
        job_type=job_type,
        user_id="00000000-0000-0000-0000-000000000002",
        payload={
            "observation_id": "00000000-0000-0000-0000-000000000003",
            "user_id": "00000000-0000-0000-0000-000000000002",
            "input_revision": 1,
            "semantic_run_id": "00000000-0000-0000-0000-000000000004",
            "ontology_version_id": "00000000-0000-0000-0000-000000000005",
            "resolver_model_id": "00000000-0000-0000-0000-000000000006",
        },
        attempts=1,
        lease_token="lease-fixture",
    )


class WorkerTests(unittest.TestCase):
    def test_empty_queue_is_a_clean_noop(self) -> None:
        queue = FakeQueue(None)
        self.assertEqual(SemanticWorker(queue).run_once(), {"claimed": False})  # type: ignore[arg-type]

    def test_unknown_handler_fails_closed_without_retry(self) -> None:
        queue = FakeQueue(job("future_job"))
        result = SemanticWorker(queue).run_once()  # type: ignore[arg-type]
        self.assertEqual(result["status"], "dead_no_handler")
        self.assertEqual(queue.failed[0][2], False)

    def test_success_persists_handler_result(self) -> None:
        queue = FakeQueue(job())
        worker = SemanticWorker(
            queue,  # type: ignore[arg-type]
            handlers={"map_observation": lambda claimed: {"mapped": claimed.id}},
        )
        self.assertEqual(worker.run_once()["status"], "succeeded")
        self.assertEqual(queue.succeeded[0][1]["mapped"], job().id)

    def test_handler_error_retries_without_leaking_message(self) -> None:
        queue = FakeQueue(job())

        def fail(_claimed: WorkerJob) -> dict[str, object]:
            raise ValueError("sensitive raw payload")

        result = SemanticWorker(
            queue,  # type: ignore[arg-type]
            handlers={"map_observation": fail},
        ).run_once()
        self.assertEqual(result["status"], "retry_scheduled")
        self.assertEqual(queue.failed[0][1], "handler_error")

    def test_invalid_payload_is_dead_before_handler_dispatch(self) -> None:
        invalid = job()
        invalid = WorkerJob(
            id=invalid.id,
            job_type=invalid.job_type,
            user_id=invalid.user_id,
            payload={**invalid.payload, "raw_calendar": "must never dispatch"},
            attempts=invalid.attempts,
            lease_token=invalid.lease_token,
        )
        called = False

        def handler(_claimed: WorkerJob) -> dict[str, object]:
            nonlocal called
            called = True
            return {}

        queue = FakeQueue(invalid)
        result = SemanticWorker(
            queue,  # type: ignore[arg-type]
            handlers={"map_observation": handler},
        ).run_once()
        self.assertEqual(result["status"], "dead_invalid_payload")
        self.assertFalse(called)
        self.assertEqual(
            queue.failed[0][1], "invalid_payload:forbidden_private_field"
        )
        self.assertFalse(queue.failed[0][2])


if __name__ == "__main__":
    unittest.main()
