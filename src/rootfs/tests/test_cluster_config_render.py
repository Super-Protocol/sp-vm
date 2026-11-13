#!/usr/bin/env python3
"""Unit tests for `cluster_config.py render`.

The rendered provider_config is the only durable input a node has, so it is
what decides the node's mode on every boot. These tests pin the two shapes
detect_swarm_pki_state() accepts, and that a node rendered as a join node
declares it may not create a swarm of its own (SUP-655).

Run with: python3 -m unittest discover -s src/rootfs/tests -p 'test_*.py'
"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

SRC = Path(__file__).resolve().parents[2]
TOOL = SRC.parent / "scripts/azure/cluster_config.py"
CA = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"


class Render(unittest.TestCase):
    def setUp(self):
        self.work = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(self.work)], check=False))
        template = self.work / "template"
        (template / "swarm").mkdir(parents=True)
        (template / "swarm" / "config.yaml").write_text(
            yaml.safe_dump(
                {
                    "swarm_db": {"node_name": "", "advertise_addr": "", "join_addresses": []},
                    "pki_authority": {"networkID": "swarm"},
                }
            ),
            encoding="utf-8",
        )
        self.template = template
        self.ca_file = self.work / "ca.pem"
        self.ca_file.write_text(CA, encoding="utf-8")

    def render(self, role, *extra):
        out = self.work / f"out-{role}-{len(extra)}"
        subprocess.run(
            [sys.executable, str(TOOL), "render", "--template", str(self.template),
             "--out", str(out), "--node-name", "node-1", "--role", role, *extra],
            check=True, capture_output=True, text=True,
        )
        return yaml.safe_load((out / "swarm" / "config.yaml").read_text(encoding="utf-8"))

    def test_bootstrap_role_declares_it_may_create_a_swarm(self):
        cfg = self.render("bootstrap")
        self.assertIs(cfg["swarm_db"]["bootstrap"], True)
        self.assertEqual(cfg["swarm_db"]["join_addresses"], [])
        self.assertNotIn("caBundle", cfg["pki_authority"])
        self.assertNotIn("servers", cfg["pki_authority"])

    def test_join_role_declares_it_may_not(self):
        cfg = self.render("join", "--peer", "10.0.0.10", "--ca", str(self.ca_file))
        self.assertIs(cfg["swarm_db"]["bootstrap"], False)
        self.assertEqual(cfg["swarm_db"]["join_addresses"], ["10.0.0.10:7946"])
        self.assertIn("BEGIN CERTIFICATE", cfg["pki_authority"]["caBundle"])
        self.assertEqual(cfg["pki_authority"]["servers"], ["10.0.0.10:9443"])

    def test_the_bootstrap_node_can_be_re_rendered_as_a_join_node(self):
        # cluster.sh promotes the bootstrap node's config this way once another
        # node serves the cluster CA, so its next boot enrols instead of
        # generating a second chain.
        cfg = self.render(
            "join", "--peer", "10.0.0.11", "--peer", "10.0.0.12", "--ca", str(self.ca_file)
        )
        self.assertIs(cfg["swarm_db"]["bootstrap"], False)
        self.assertEqual(
            cfg["swarm_db"]["join_addresses"], ["10.0.0.11:7946", "10.0.0.12:7946"]
        )
        self.assertEqual(
            cfg["pki_authority"]["servers"], ["10.0.0.11:9443", "10.0.0.12:9443"]
        )


if __name__ == "__main__":
    unittest.main()
