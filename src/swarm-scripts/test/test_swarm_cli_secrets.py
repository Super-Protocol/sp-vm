#!/usr/bin/env python3
"""SwarmSecrets must be written once and then left alone (SUP-700).

The RKE2 join token is sealed into the cluster's etcd bootstrap data and the PKI
auth token is handed to every node, so a second `create` that overwrites either
one strands the swarm: running nodes keep working, new nodes can never join.
`00-initialize-secrets.sh` re-runs on every boot of the swarm-init node, which
makes "create, or leave the existing row alone" the whole contract of these two
commands.

It used to be enforced by `ON DUPLICATE KEY UPDATE value = value` in the insert.
That is a MySQL idiom; SwarmDB resolves every insert as a last-writer-wins
upsert, so it silently overwrote. The protection is now an explicit SELECT,
which is what these tests pin.

Run: python3 src/swarm-scripts/test/test_swarm_cli_secrets.py
Needs: sqlalchemy, pymysql (the same imports swarm-cli.py itself needs).
"""

from __future__ import annotations

import importlib.util
import io
import json
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

from sqlalchemy import create_engine, text

SCRIPTS_DIR = Path(__file__).resolve().parents[1]


def _load_swarm_cli():
    spec = importlib.util.spec_from_file_location("swarm_cli", SCRIPTS_DIR / "swarm-cli.py")
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


swarm_cli = _load_swarm_cli()

EXISTING = "the-token-this-cluster-was-bootstrapped-with"
REPLACEMENT = "a-freshly-generated-one"


class SwarmSecretsTestCase(unittest.TestCase):
    def setUp(self):
        # SQLite stands in for SwarmDB here: these tests are about which
        # statements the CLI decides to run, not about the engine's dialect.
        self.engine = create_engine("sqlite://")
        with self.engine.begin() as conn:
            conn.execute(text("CREATE TABLE SwarmSecrets (id TEXT PRIMARY KEY, value TEXT)"))

    def seed(self, secret_id: str, value: str):
        with self.engine.begin() as conn:
            conn.execute(
                text("INSERT INTO SwarmSecrets (id, value) VALUES (:id, :value)"),
                {"id": secret_id, "value": value},
            )

    def stored(self, secret_id: str):
        with self.engine.connect() as conn:
            return conn.execute(
                text("SELECT value FROM SwarmSecrets WHERE id = :id"), {"id": secret_id}
            ).scalar()

    def args(self, argv: list[str]):
        return swarm_cli.parse_args(argv)

    def run_cmd(self, func, argv: list[str]):
        """Run a command handler, returning its stdout."""
        out = io.StringIO()
        with redirect_stdout(out):
            func(self.args(argv), {}, self.engine)
        return out.getvalue()

    # create ---------------------------------------------------------------

    def test_create_writes_the_row_when_it_is_absent(self):
        with patch.object(swarm_cli, "run_sql") as run_sql:
            out = self.run_cmd(
                swarm_cli.create_swarm_secrets,
                ["create", "SwarmSecrets", "rke2_join_token", "--value", EXISTING],
            )

        run_sql.assert_called_once()
        statement, params = run_sql.call_args[0][1], run_sql.call_args[0][2]
        self.assertIn("INSERT INTO SwarmSecrets", statement)
        self.assertEqual(params, {"id": "rke2_join_token", "value": EXISTING})
        self.assertIn("created", out)

    def test_create_leaves_an_existing_row_alone(self):
        """The regression: a second boot must not rotate the join token."""
        self.seed("rke2_join_token", EXISTING)

        with patch.object(swarm_cli, "run_sql") as run_sql:
            out = self.run_cmd(
                swarm_cli.create_swarm_secrets,
                ["create", "SwarmSecrets", "rke2_join_token", "--value", REPLACEMENT],
            )

        run_sql.assert_not_called()
        self.assertEqual(self.stored("rke2_join_token"), EXISTING)
        self.assertIn("already exists", out)

    def test_create_refuses_to_write_when_the_lookup_fails(self):
        """A broken query is not an answer: guessing "absent" is what overwrites."""
        with self.engine.begin() as conn:
            conn.execute(text("DROP TABLE SwarmSecrets"))

        with patch.object(swarm_cli, "run_sql") as run_sql:
            with self.assertRaises(SystemExit) as exit_ctx:
                self.run_cmd(
                    swarm_cli.create_swarm_secrets,
                    ["create", "SwarmSecrets", "rke2_join_token", "--value", REPLACEMENT],
                )

        self.assertEqual(exit_ctx.exception.code, 2)
        run_sql.assert_not_called()

    # get ------------------------------------------------------------------

    def test_get_is_wired_into_the_dispatch_chain(self):
        """`get SwarmSecrets` used to fall through to "Unsupported command"."""
        self.seed("pki_auth_token", EXISTING)

        with patch.object(swarm_cli, "create_engine_from_env", return_value=self.engine):
            out = io.StringIO()
            with redirect_stdout(out):
                swarm_cli.main(["get", "SwarmSecrets", "pki_auth_token"])

        self.assertEqual(json.loads(out.getvalue()), {"id": "pki_auth_token"})

    def test_get_withholds_the_value_unless_asked(self):
        self.seed("rke2_join_token", EXISTING)

        bare = self.run_cmd(swarm_cli.get_swarm_secrets, ["get", "SwarmSecrets", "rke2_join_token"])
        self.assertEqual(json.loads(bare), {"id": "rke2_join_token"})
        self.assertNotIn(EXISTING, bare)

        shown = self.run_cmd(
            swarm_cli.get_swarm_secrets,
            ["get", "SwarmSecrets", "rke2_join_token", "--show-value"],
        )
        self.assertEqual(json.loads(shown), {"id": "rke2_join_token", "value": EXISTING})

    def test_get_exits_1_when_the_row_is_absent(self):
        with self.assertRaises(SystemExit) as exit_ctx:
            self.run_cmd(swarm_cli.get_swarm_secrets, ["get", "SwarmSecrets", "nothing_here"])
        self.assertEqual(exit_ctx.exception.code, 1)

    def test_get_exits_2_when_the_query_fails(self):
        """Distinct from exit 1 — ensure_secret treats only 1 as "go ahead and create"."""
        with self.engine.begin() as conn:
            conn.execute(text("DROP TABLE SwarmSecrets"))

        with self.assertRaises(SystemExit) as exit_ctx:
            self.run_cmd(swarm_cli.get_swarm_secrets, ["get", "SwarmSecrets", "rke2_join_token"])
        self.assertEqual(exit_ctx.exception.code, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
