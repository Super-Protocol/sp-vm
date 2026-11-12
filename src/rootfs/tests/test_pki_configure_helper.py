#!/usr/bin/env python3
"""Unit tests for the VM mode decision in pki_configure_helper.py.

The mode decides whether a boot creates a new PKI chain and a new swarm key or
enrols into an existing swarm, and nothing the `init` path writes survives a
reboot. A wrong decision on the node that bootstrapped the swarm partitions or
forks it (SUP-655), and the only way to see that on a VM is to reboot one, so
the decision is covered here instead.

Run with: python3 -m unittest discover -s src/rootfs/tests -p 'test_*.py'
"""

import importlib.util
import unittest
from pathlib import Path

SRC = Path(__file__).resolve().parents[2]
HELPER = SRC / "rootfs/files/configs/pki-service/scripts/pki_configure_helper.py"

_spec = importlib.util.spec_from_file_location("pki_configure_helper", HELPER)
helper = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(helper)

CA = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"


def config(*, join=None, ca=None, servers=None, bootstrap="absent"):
    swarm_db = {"node_name": "node-1", "join_addresses": join if join is not None else []}
    if bootstrap != "absent":
        swarm_db["bootstrap"] = bootstrap
    return {
        "swarm_db": swarm_db,
        "pki_authority": {
            "networkID": "swarm",
            "caBundle": ca if ca is not None else "",
            "servers": servers if servers is not None else [],
        },
    }


FULL_PEER_INFO = {"join": ["10.0.0.10:7946"], "ca": CA, "servers": ["10.0.0.10:9443"]}


class DetectSwarmPkiState(unittest.TestCase):
    def test_no_peer_info_and_bootstrap_declared_creates_a_swarm(self):
        self.assertEqual(helper.detect_swarm_pki_state(config(bootstrap=True)), "init")

    def test_no_peer_info_and_no_declaration_still_creates_a_swarm(self):
        # Every provider_config written before swarm_db.bootstrap existed has
        # this shape; it must keep bootstrapping.
        self.assertEqual(helper.detect_swarm_pki_state(config()), "init")

    def test_no_peer_info_and_bootstrap_refused_is_an_error(self):
        with self.assertRaises(ValueError) as caught:
            helper.detect_swarm_pki_state(config(bootstrap=False))
        self.assertIn("Refusing to create a swarm", str(caught.exception))

    def test_peer_info_enrols(self):
        self.assertEqual(helper.detect_swarm_pki_state(config(**FULL_PEER_INFO)), "normal")

    def test_peer_info_wins_over_the_bootstrap_declaration(self):
        # This is the reboot of the node that bootstrapped the swarm: its
        # provider_config still says bootstrap, and now also names the swarm it
        # created. It must enrol, not generate a second chain.
        self.assertEqual(
            helper.detect_swarm_pki_state(config(bootstrap=True, **FULL_PEER_INFO)),
            "normal",
        )

    def test_peer_info_with_bootstrap_refused_enrols(self):
        self.assertEqual(
            helper.detect_swarm_pki_state(config(bootstrap=False, **FULL_PEER_INFO)),
            "normal",
        )

    def test_partial_peer_info_is_an_error(self):
        for name, partial in (
            ("join addresses only", {"join": ["10.0.0.10:7946"]}),
            ("ca only", {"ca": CA}),
            ("servers only", {"servers": ["10.0.0.10:9443"]}),
            ("no servers", {"join": ["10.0.0.10:7946"], "ca": CA}),
            ("no ca", {"join": ["10.0.0.10:7946"], "servers": ["10.0.0.10:9443"]}),
        ):
            for bootstrap in (True, False, "absent"):
                with self.subTest(partial=name, bootstrap=bootstrap):
                    with self.assertRaises(ValueError) as caught:
                        helper.detect_swarm_pki_state(config(bootstrap=bootstrap, **partial))
                    self.assertIn("either all empty", str(caught.exception))

    def test_bootstrap_must_be_a_boolean(self):
        with self.assertRaises(ValueError) as caught:
            helper.detect_swarm_pki_state(config(bootstrap="yes"))
        self.assertIn("swarm_db.bootstrap", str(caught.exception))

    def test_a_missing_swarm_db_section_creates_a_swarm(self):
        self.assertEqual(helper.detect_swarm_pki_state({"pki_authority": {}}), "init")

    def test_non_mapping_sections_are_rejected(self):
        with self.assertRaises(ValueError):
            helper.detect_swarm_pki_state({"swarm_db": ["10.0.0.10"]})
        with self.assertRaises(ValueError):
            helper.detect_swarm_pki_state({"pki_authority": ["10.0.0.10"]})


class ReadOptionalBool(unittest.TestCase):
    def test_absent_is_none(self):
        self.assertIsNone(helper.read_optional_bool(None, "swarm_db.bootstrap"))

    def test_booleans_pass_through(self):
        self.assertIs(helper.read_optional_bool(True, "swarm_db.bootstrap"), True)
        self.assertIs(helper.read_optional_bool(False, "swarm_db.bootstrap"), False)

    def test_a_string_is_rejected(self):
        # YAML `bootstrap: "false"` is a non-empty string, and treating it as
        # truthy would create a swarm on a node told not to.
        with self.assertRaises(ValueError):
            helper.read_optional_bool("false", "swarm_db.bootstrap")


if __name__ == "__main__":
    unittest.main()
