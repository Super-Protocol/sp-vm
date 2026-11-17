"""
swarm-cli.py is how the bootstrap scripts write the swarm's long-lived secrets,
and it has to keep an existing row rather than replace it: the RKE2 join token,
the PKI auth token and the PKI material are all minted once and then depended
on forever. SwarmDB does not implement MySQL's `INSERT IGNORE` or
`ON DUPLICATE KEY UPDATE value = value` — both land as a last-writer-wins
upsert — so "do not overwrite" has to be enforced by reading first (SUP-700).

These tests drive the real CLI against a throwaway SQLite database, which is
enough to pin the two things that broke: which commands the dispatcher answers,
and whether a second create replaces the stored value. SQLite cannot reproduce
SwarmDB's upsert semantics, and that is the point — after the fix the CLI no
longer asks any backend to arbitrate a conflict, so the guarantee holds the
same way everywhere.
"""

import contextlib
import importlib.util
import io
import json
import os
import re
import sys
import tempfile
import unittest

SCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI_PATH = os.path.join(SCRIPTS_DIR, "swarm-cli.py")
INITIALIZE_SECRETS_PATH = os.path.join(SCRIPTS_DIR, "00-initialize-secrets.sh")


def load_cli():
    spec = importlib.util.spec_from_file_location("swarm_cli", CLI_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


swarm_cli = load_cli()


class SwarmCliTestCase(unittest.TestCase):
    """Runs swarm-cli.py's main() against a SQLite stand-in for SwarmDB."""

    def setUp(self):
        from sqlalchemy import create_engine, text

        self._text = text
        handle, self.db_path = tempfile.mkstemp(suffix=".sqlite")
        os.close(handle)
        self.addCleanup(os.unlink, self.db_path)

        self.engine = create_engine(f"sqlite+pysqlite:///{self.db_path}", future=True)
        self.addCleanup(self.engine.dispose)
        with self.engine.begin() as conn:
            conn.execute(text("CREATE TABLE SwarmSecrets (id TEXT PRIMARY KEY, value TEXT)"))
            conn.execute(text("CREATE TABLE SwarmIdPointer (id TEXT PRIMARY KEY, value TEXT)"))

        original = swarm_cli.create_engine_from_env
        swarm_cli.create_engine_from_env = lambda db: self.engine
        self.addCleanup(setattr, swarm_cli, "create_engine_from_env", original)

    def run_cli(self, *argv):
        """Returns (exit_code, stdout). Exit code 0 means main() returned."""
        out = io.StringIO()
        code = 0
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            try:
                swarm_cli.main(list(argv))
            except SystemExit as exc:
                code = exc.code if isinstance(exc.code, int) else 1
        return code, out.getvalue()

    def stored(self, table, id_value):
        with self.engine.connect() as conn:
            row = conn.execute(
                self._text(f"SELECT value FROM {table} WHERE id = :id"), {"id": id_value}
            ).first()
        return None if row is None else row[0]


class CreateSwarmSecretsTest(SwarmCliTestCase):
    def test_creates_the_row_when_the_swarm_has_none(self):
        code, _ = self.run_cli("create", "SwarmSecrets", "rke2_join_token", "--value", "FIRST")
        self.assertEqual(code, 0)
        self.assertEqual(self.stored("SwarmSecrets", "rke2_join_token"), "FIRST")

    def test_a_rerun_keeps_the_stored_secret(self):
        # The swarm-init node runs 00-initialize-secrets.sh on every boot with a
        # freshly generated token. The second write must not land, or the running
        # cluster's nodes are the only ones that can ever hold a valid token.
        self.run_cli("create", "SwarmSecrets", "rke2_join_token", "--value", "FIRST")
        code, _ = self.run_cli("create", "SwarmSecrets", "rke2_join_token", "--value", "SECOND")
        self.assertEqual(code, 0, "a rerun must succeed, not fail on the duplicate key")
        self.assertEqual(self.stored("SwarmSecrets", "rke2_join_token"), "FIRST")

    def test_other_secrets_are_unaffected(self):
        self.run_cli("create", "SwarmSecrets", "pki_auth_token", "--value", "TOKEN")
        self.run_cli("create", "SwarmSecrets", "base_domain", "--value", "example.test")
        self.run_cli("create", "SwarmSecrets", "pki_auth_token", "--value", "ROTATED")
        self.assertEqual(self.stored("SwarmSecrets", "pki_auth_token"), "TOKEN")
        self.assertEqual(self.stored("SwarmSecrets", "base_domain"), "example.test")

    def test_a_value_is_required(self):
        code, _ = self.run_cli("create", "SwarmSecrets", "rke2_join_token")
        self.assertEqual(code, 1)
        self.assertIsNone(self.stored("SwarmSecrets", "rke2_join_token"))


class GetSwarmSecretsTest(SwarmCliTestCase):
    def test_an_existing_secret_exits_zero(self):
        # This is the exit code 00-initialize-secrets.sh reads as "already there".
        self.run_cli("create", "SwarmSecrets", "rke2_join_token", "--value", "FIRST")
        code, out = self.run_cli("get", "SwarmSecrets", "rke2_join_token")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out), {"id": "rke2_join_token"})

    def test_the_secret_value_is_not_printed(self):
        self.run_cli("create", "SwarmSecrets", "rke2_join_token", "--value", "SUPERSECRET")
        _, out = self.run_cli("get", "SwarmSecrets", "rke2_join_token")
        self.assertNotIn("SUPERSECRET", out)

    def test_a_missing_secret_exits_one(self):
        code, _ = self.run_cli("get", "SwarmSecrets", "nothing_here")
        self.assertEqual(code, 1)

    def test_an_id_is_required(self):
        code, _ = self.run_cli("get", "SwarmSecrets")
        self.assertEqual(code, 2)


class CreateSwarmIdPointerTest(SwarmCliTestCase):
    def test_a_rerun_keeps_the_stored_pointer(self):
        self.run_cli("create", "SwarmIdPointer", "global_id", "--value", "g1")
        code, _ = self.run_cli("create", "SwarmIdPointer", "global_id", "--value", "g2")
        self.assertEqual(code, 0)
        self.assertEqual(self.stored("SwarmIdPointer", "global_id"), "g1")


class DispatchTest(unittest.TestCase):
    """
    The guard in ensure_secret short-circuits on the CLI's exit code, so a
    command the dispatcher does not answer makes it fail open silently: the
    probe exits 1 ("Unsupported command"), the script reads that as "no secret
    yet" and writes. `get SwarmSecrets` was missing for exactly that reason.
    """

    def test_every_command_the_bootstrap_script_issues_is_dispatched(self):
        with open(INITIALIZE_SECRETS_PATH, encoding="utf-8") as handle:
            script = handle.read()

        issued = set(
            re.findall(r'swarm-cli\.py"?\s+(create|get)\s+(\w+)', script)
        )
        self.assertTrue(issued, "found no swarm-cli.py invocations to check")

        for action, entity in sorted(issued):
            with self.subTest(command=f"{action} {entity}"):
                self.assertIn(f"{action}:{entity}", swarm_cli.COMMANDS)

    def test_an_unknown_command_is_still_rejected(self):
        self.assertNotIn("delete:SwarmSecrets", swarm_cli.COMMANDS)


if __name__ == "__main__":
    unittest.main()
