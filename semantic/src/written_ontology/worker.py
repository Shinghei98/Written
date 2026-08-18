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
        except Exception:  # noqa: BLE001 - worker boundary
            self.queue.fail(
                job.id,
                "handler_error",
                retry=True,
                lease_token=job.lease_token,
            )
            return {"claimed": True, "job_id": job.id, "status": "retry_scheduled"}
        # **A handler that has not finished must not be marked as having
        # finished.** Every non-raising return used to succeed the job, so an
        # accepted-but-unanswered model call — the ordinary state while a
        # scaled-to-zero GPU starts — closed the job, and the answer nobody
        # collected sat in a bucket until the lifecycle rule removed it. The
        # work was done, paid for, and thrown away.
        #
        # `in_flight` is the one status that means *come back*, and it is
        # deliberately not an exception: raising would record `handler_error`,
        # which is a claim that something went wrong.
        if isinstance(result, dict) and result.get("status") == "in_flight":
            self.queue.fail(job.id, "in_flight", retry=True,
                            lease_token=job.lease_token)
            return {"claimed": True, "job_id": job.id,
                    "status": "retry_scheduled", "reason": "in_flight"}
        self.queue.succeed(job.id, result, lease_token=job.lease_token)
        return {"claimed": True, "job_id": job.id, "status": "succeeded"}
