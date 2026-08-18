from __future__ import annotations

from collections.abc import Callable
from typing import Any

from .job_contracts import (
    DEFAULT_JOB_CONTRACT_REGISTRY,
    JobContractError,
    JobContractRegistry,
)
from .repository import PostgresJobQueue, WorkerJob


JobHandler = Callable[[WorkerJob], dict[str, Any]]


def _deferred_types() -> tuple[type[BaseException], ...]:
    """The deferral exception, if the handler package defines one.

    Imported lazily and tolerantly: the queue runner is vendored and must not
    fail to load because a handler module is absent in some deployment.
    """
    try:
        from overlay import InferenceDeferred  # noqa: PLC0415
    except Exception:  # noqa: BLE001
        class InferenceDeferred(Exception):  # noqa: N801 - unreachable sentinel
            pass
    return (InferenceDeferred,)


class SemanticWorker:
    def __init__(
        self,
        queue: PostgresJobQueue,
        handlers: dict[str, JobHandler] | None = None,
        contract_registry: JobContractRegistry = DEFAULT_JOB_CONTRACT_REGISTRY,
    ) -> None:
        self.queue = queue
        self.handlers = handlers or {}
        self.contract_registry = contract_registry

    def run_once(self) -> dict[str, Any]:
        job = self.queue.claim()
        if job is None:
            return {"claimed": False}
        handler = self.handlers.get(job.job_type)
        if handler is None:
            # Fail closed: a starter must never mark an unimplemented semantic
            # mutation as successful.
            self.queue.fail(
                job.id,
                f"no_handler:{job.job_type}",
                retry=False,
                lease_token=job.lease_token,
            )
            return {"claimed": True, "job_id": job.id, "status": "dead_no_handler"}
        try:
            self.contract_registry.validate(
                job.job_type,
                job.payload,
                queue_user_id=job.user_id,
            )
        except JobContractError as error:
            # Payload validation happens before dispatch. Persist only the
            # stable code; neither field values nor raw exception text enter
            # the queue's error column.
            self.queue.fail(
                job.id,
                f"invalid_payload:{error.code}",
                retry=False,
                lease_token=job.lease_token,
            )
            return {
                "claimed": True,
                "job_id": job.id,
                "status": "dead_invalid_payload",
            }
        try:
            result = handler(job)
        except _deferred_types() as deferred:  # noqa: PERF203 - one narrow case
            # **A deferral is not a failure.** The work exists and is running;
            # recording `handler_error` would spend an ordinary attempt and
            # eventually mark the job dead while the inference it waits for is
            # fine. `defer` re-queues without touching `last_error` or the
            # attempt count.
            self.queue.defer(job.id, lease_token=job.lease_token,
                             delay_seconds=getattr(deferred, "delay_seconds", 120))
            return {"claimed": True, "job_id": job.id, "status": "deferred"}
        except Exception:  # noqa: BLE001 - worker boundary
            self.queue.fail(
                job.id,
                "handler_error",
                retry=True,
                lease_token=job.lease_token,
            )
            return {"claimed": True, "job_id": job.id, "status": "retry_scheduled"}
        # A handler that has not finished raises `InferenceDeferred` and is
        # handled above. It cannot say so in its result: `in_flight` is not one
        # of the nine status words the receipt schema permits, so a result
        # carrying it would be refused by the database.
        self.queue.succeed(job.id, result, lease_token=job.lease_token)
        return {"claimed": True, "job_id": job.id, "status": "succeeded"}
