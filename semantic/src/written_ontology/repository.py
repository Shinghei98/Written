from __future__ import annotations

from dataclasses import dataclass
from typing import Any
from uuid import uuid4


@dataclass(frozen=True, slots=True)
class WorkerJob:
    id: str
    job_type: str
    user_id: str | None
    payload: dict[str, Any]
    attempts: int
    lease_token: str


class PostgresJobQueue:
    """Small Postgres outbox using FOR UPDATE SKIP LOCKED.

    psycopg is imported lazily so the offline demo remains dependency-free.
    """

    def __init__(self, database_url: str, worker_id: str, lease_seconds: int = 300) -> None:
        self.database_url = database_url
        self.worker_id = worker_id
        if lease_seconds < 30:
            raise ValueError("lease_seconds must be at least 30")
        self.lease_seconds = lease_seconds

    def _connect(self):  # type: ignore[no-untyped-def]
        try:
            import psycopg
            from psycopg.rows import dict_row
        except ImportError as error:
            raise RuntimeError("install the postgres extra: pip install -e '.[postgres]'") from error
        return psycopg.connect(self.database_url, row_factory=dict_row)

    def claim(self) -> WorkerJob | None:
        lease_token = f"{self.worker_id}:{uuid4()}"
        statement = """
        with exhausted as (
          update private.worker_jobs
          set status = 'dead', locked_at = null, locked_by = null,
              last_error = 'lease_expired_after_max_attempts'
          where attempts >= 5
            and (
              status = 'queued'
              or (
                status = 'running'
                and locked_at < now() - make_interval(secs => %(lease_seconds)s)
              )
            )
          returning id
        ), candidate as (
          select id
          from private.worker_jobs
          where attempts < 5
            and (
              (status = 'queued' and available_at <= now())
              or (
                status = 'running'
                and locked_at < now() - make_interval(secs => %(lease_seconds)s)
              )
            )
          order by available_at, created_at
          for update skip locked
          limit 1
        )
        update private.worker_jobs as job
        set status = 'running',
            locked_at = now(),
            locked_by = %(lease_token)s,
            attempts = attempts + 1
        from candidate
        where job.id = candidate.id
        returning job.id::text, job.job_type, job.user_id::text, job.payload,
                  job.attempts, job.locked_by
        """
        with self._connect() as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    statement,
                    {
                        "lease_token": lease_token,
                        "lease_seconds": self.lease_seconds,
                    },
                )
                row = cursor.fetchone()
            connection.commit()
        if row is None:
            return None
        return WorkerJob(
            id=row["id"],
            job_type=row["job_type"],
            user_id=row["user_id"],
            payload=row["payload"],
            attempts=row["attempts"],
            lease_token=row["locked_by"],
        )

    def succeed(
        self,
        job_id: str,
        result: dict[str, Any] | None,
        *,
        lease_token: str,
    ) -> None:
        try:
            from psycopg.types.json import Jsonb
        except ImportError as error:
            raise RuntimeError("install the postgres extra: pip install -e '.[postgres]'") from error
        with self._connect() as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    update private.worker_jobs
                    set status = 'succeeded', locked_at = null, locked_by = null,
                        result = %(result)s::jsonb, last_error = null
                    where id = %(job_id)s::uuid and locked_by = %(lease_token)s
                    """,
                    {
                        "job_id": job_id,
                        "lease_token": lease_token,
                        "result": Jsonb(result or {}),
                    },
                )
                if cursor.rowcount != 1:
                    raise RuntimeError("job lease was lost before success could be persisted")
            connection.commit()

    def fail(
        self,
        job_id: str,
        error_code: str,
        retry: bool = True,
        *,
        lease_token: str,
    ) -> None:
        with self._connect() as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    update private.worker_jobs
                    set status = case when %(retry)s and attempts < 5 then 'queued' else 'dead' end,
                        available_at = case
                          when %(retry)s and attempts < 5
                          then now() + make_interval(secs => least(3600, power(2, attempts)::integer * 15))
                          else available_at
                        end,
                        locked_at = null, locked_by = null, last_error = %(error_code)s
                    where id = %(job_id)s::uuid and locked_by = %(lease_token)s
                    """,
                    {
                        "job_id": job_id,
                        "lease_token": lease_token,
                        "retry": retry,
                        "error_code": error_code[:500],
                    },
                )
                if cursor.rowcount != 1:
                    raise RuntimeError("job lease was lost before failure could be persisted")
            connection.commit()
