"""The probe proves a credential by using it, and proves nothing else by writing.

**A credential is only checked by using it.** Everything
`tools/verify_worker_deployment.sh` could see before this — a secret exists, it
holds a value, a policy is attached — was equally true while
`semantic_model_worker` could not log in at all, which is the state the model
lane shipped in and the state nothing reported.

So `ModelLane.probe()` opens the real connection through the real secret. What
these tests pin is the other half: that it is a **probe** and not a small
`propose`. It must never reach the gateway, never record an invocation, and
never commit — and it must say which check failed rather than raising on the
first one, because a deployment verifier that reports one problem per run costs
a round trip per problem.
"""
from __future__ import annotations

import importlib.util
import json
import pathlib
import sys

import pytest

REPOSITORY = pathlib.Path(__file__).resolve().parents[2]


@pytest.fixture(scope="module")
def model_lane():
    sys.path.insert(0, str(REPOSITORY / "aws" / "worker"))
    spec = importlib.util.spec_from_file_location(
        "model_lane_under_test", REPOSITORY / "aws" / "worker" / "model_lane.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class FakeCursor:
    """Answers the three catalogue reads by shape, not by parsing SQL."""

    def __init__(self, connection, *, who, executable, writable):
        self.connection = connection
        self.who = who
        self.executable = executable
        self.writable = writable
        self.rows: list[dict] = []

    def __enter__(self): return self
    def __exit__(self, *a): return False

    def execute(self, sql, args=None):
        self.connection.statements.append(sql)
        if "current_user as who" in sql:
            self.rows = [{"who": self.who, "db": "postgres", "networked": True}]
        elif "pg_proc" in sql:
            self.rows = [{"proname": name,
                          "signature": f"semantic_private.{name}(integer)",
                          "may": name in self.executable}
                         for name in args[0]]
        elif "pg_class" in sql:
            self.rows = [{"relname": name,
                          "ins": name in self.writable,
                          "upd": False}
                         for name in args[0]]
        else:  # pragma: no cover - a fourth read would be a design change
            raise AssertionError(f"the probe asked something unexpected: {sql}")

    def fetchall(self): return list(self.rows)
    def fetchone(self): return self.rows[0]


class FakeConnection:
    def __init__(self, *, who="semantic_model_worker", executable=(), writable=()):
        self.who = who
        self.executable = executable
        self.writable = writable
        self.statements: list[str] = []
        self.committed = False
        self.rolled_back = False

    def cursor(self):
        return FakeCursor(self, who=self.who, executable=self.executable,
                          writable=self.writable)

    def commit(self): self.committed = True
    def rollback(self): self.rolled_back = True
    def __enter__(self): return self
    def __exit__(self, *a): return False


def lane(model_lane, connection):
    """A lane wired to a fake connection and a gateway client that refuses.

    The `lambda_client` is deliberately hostile: if the probe ever grows a
    gateway call, the test fails loudly rather than quietly passing against a
    mock that answered.
    """
    class Hostile:
        def invoke(self, **kwargs):
            raise AssertionError("the probe called the gateway")

    class Secrets:
        """The real shape, so the probe exercises the real DSN builder."""

        def get_secret_value(self, SecretId):  # noqa: N803 - boto3's spelling
            return {"SecretString": json.dumps({
                "user": "semantic_model_worker.abcdefghijklmnop",
                "password": "not-a-real-password",
                "host": "aws-0-us-east-1.pooler.supabase.com",
                "port": 6543, "dbname": "postgres"})}

    return model_lane.ModelLane(
        lambda_client=Hostile(),
        secrets_client=Secrets(),
        connect=lambda dsn: connection,
        secret_id="written/semantic-model-worker")


def test_a_correctly_deployed_lane_passes_every_check(model_lane):
    connection = FakeConnection(
        who="semantic_model_worker",
        executable=model_lane.ModelLane.PROBE_MUST_EXECUTE,
        writable=())
    result = lane(model_lane, connection).probe()

    assert result["ok"] is True
    assert [check["ok"] for check in result["checks"]] == [True, True, True, True]


def test_the_wrong_role_is_reported_and_is_not_an_exception(model_lane):
    """The failure this exists for: a password that lands on the wrong identity.

    A pooler authenticates a username and assumes a role behind it, so a
    connection succeeding says nothing about *whose* grants are in force.
    """
    connection = FakeConnection(
        who="semantic_worker",
        executable=model_lane.ModelLane.PROBE_MUST_EXECUTE,
        writable=())
    result = lane(model_lane, connection).probe()

    assert result["ok"] is False
    wrong = [c for c in result["checks"] if not c["ok"]]
    assert len(wrong) == 1
    assert "semantic_worker" in wrong[0]["detail"]


def test_a_lane_that_could_write_a_mention_fails(model_lane):
    """`0239`'s list, asked of the deployment rather than of the migration."""
    connection = FakeConnection(
        executable=model_lane.ModelLane.PROBE_MUST_EXECUTE,
        writable=("observation_mentions",))
    result = lane(model_lane, connection).probe()

    assert result["ok"] is False
    assert any("observation_mentions" in c["detail"]
               for c in result["checks"] if not c["ok"])


def test_a_missing_function_is_a_failure_not_an_absence(model_lane):
    """A lane that cannot find what it exists to call is as broken as one refused it."""
    connection = FakeConnection(executable=("model_invocation_lineage",))
    result = lane(model_lane, connection).probe()

    assert result["ok"] is False
    assert any(c["check"] == "may execute record_model_invocation" and not c["ok"]
               for c in result["checks"])


def test_it_rolls_back_and_never_commits(model_lane):
    """**The safety is stated, not inherited from having run only selects.**"""
    connection = FakeConnection(
        executable=model_lane.ModelLane.PROBE_MUST_EXECUTE)
    lane(model_lane, connection).probe()

    assert connection.rolled_back is True
    assert connection.committed is False


def test_it_records_no_invocation(model_lane):
    """No statement the probe issues may write the lane's own tables."""
    connection = FakeConnection(
        executable=model_lane.ModelLane.PROBE_MUST_EXECUTE)
    lane(model_lane, connection).probe()

    # **Every statement is a select**, which is the assertion that means
    # something. Grepping for "insert"/"update" would not: the probe asks
    # `has_table_privilege(current_user, c.oid, 'UPDATE')`, so those words are
    # in a read by design and a naive check passes for the wrong reason.
    for statement in connection.statements:
        assert statement.strip().lower().startswith("select"), statement
    assert "record_model_invocation(" not in " ".join(connection.statements)

    # Three catalogue reads, so a fourth has to be added here deliberately.
    assert len(connection.statements) == 3


def test_no_credential_is_a_refusal_the_caller_can_render(model_lane):
    """`LaneUnavailable`, as everywhere else in this module — never a bare crash."""
    bare = model_lane.ModelLane(secret_id="")
    with pytest.raises(model_lane.LaneUnavailable):
        bare.probe()
