#!/usr/bin/env python3
"""Unit tests for pki_configure_helper.py — the script every guest runs at boot.

Two things it decides, both only observable on a real VM and both covered here
instead:

* **The VM mode** (SUP-655). The mode decides whether a boot creates a new PKI
  chain and a new swarm key or enrols into an existing swarm, and nothing the
  `init` path writes survives a reboot. A wrong decision on the node that
  bootstrapped the swarm partitions or forks it.
* **The certificate lifetime hierarchy** (SUP-653). The chain is generated once,
  on the bootstrap node, and nothing renews it, so a certificate configured to
  outlive the certificate that signs it is orphaned before it expires — a fault
  that only surfaces months later, as an evidence bundle that no longer
  verifies.

Run with: python3 -m unittest discover -s src/rootfs/tests -p 'test_*.py'
"""

import copy
import importlib.util
import tempfile
import unittest
from pathlib import Path

SRC = Path(__file__).resolve().parents[2]
HELPER = SRC / "rootfs/files/configs/pki-service/scripts/pki_configure_helper.py"
TEMPLATE_PATH = SRC / "rootfs/files/configs/pki-service/conf/cert-gen-config-template.yaml"

_spec = importlib.util.spec_from_file_location("pki_configure_helper", HELPER)
helper = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(helper)

yaml = helper.yaml

# --- SUP-655: the VM mode decision ------------------------------------------

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


# --- SUP-653: the certificate lifetime hierarchy ------------------------------

def _template() -> dict:
    return yaml.safe_load(TEMPLATE_PATH.read_text(encoding="utf-8"))


def _lifetime(template: dict, cert_id: str) -> int:
    for cert in template["certificates"]:
        if cert["id"] == cert_id:
            return cert["certParams"]["lifetimeDays"]
    raise AssertionError(f"no certificate '{cert_id}' in the template")


def _set_lifetime(template: dict, cert_role: str, days: int) -> dict:
    patched = copy.deepcopy(template)
    for cert in patched["certificates"]:
        if cert["certRole"] == cert_role:
            cert["certParams"]["lifetimeDays"] = days
    return patched


class ShippedTemplateTest(unittest.TestCase):
    def test_shipped_template_passes_the_guard(self):
        helper.validate_cert_lifetimes(_template())

    def test_every_subroot_lives_as_long_as_its_root(self):
        template = _template()
        for cert in template["certificates"]:
            if cert["certRole"] != "subroot":
                continue
            with self.subTest(cert=cert["id"]):
                self.assertEqual(
                    cert["certParams"]["lifetimeDays"],
                    _lifetime(template, cert["signer"]),
                    "a subroot shorter than its root reintroduces the SUP-653 cliff",
                )

    def test_the_retired_ninety_day_subroots_are_rejected(self):
        # The pre-SUP-653 template: 3650-day roots, 90-day subroots, a 365-day VM
        # certificate signed by one of them.
        regressed = _set_lifetime(_template(), "subroot", 90)
        with self.assertRaises(ValueError) as caught:
            helper.validate_cert_lifetimes(regressed)
        self.assertIn("must not outlive its issuer", str(caught.exception))


class ValidateCertLifetimesTest(unittest.TestCase):
    def test_accepts_a_subordinate_shorter_than_its_signer(self):
        helper.validate_cert_lifetimes(
            {
                "certificates": [
                    {"id": "root", "certRole": "root", "certParams": {"lifetimeDays": 3650}},
                    {
                        "id": "leaf",
                        "certRole": "endentity",
                        "signer": "root",
                        "certParams": {"lifetimeDays": 365},
                    },
                ]
            }
        )

    def test_accepts_a_subordinate_equal_to_its_signer(self):
        helper.validate_cert_lifetimes(
            {
                "certificates": [
                    {"id": "root", "certRole": "root", "certParams": {"lifetimeDays": 3650}},
                    {
                        "id": "sub",
                        "certRole": "subroot",
                        "signer": "root",
                        "certParams": {"lifetimeDays": 3650},
                    },
                ]
            }
        )

    def test_rejects_a_subordinate_longer_than_its_signer(self):
        with self.assertRaises(ValueError) as caught:
            helper.validate_cert_lifetimes(
                {
                    "certificates": [
                        {"id": "sub", "certRole": "subroot", "signer": "root",
                         "certParams": {"lifetimeDays": 90}},
                        {"id": "root", "certRole": "root",
                         "certParams": {"lifetimeDays": 30}},
                    ]
                }
            )
        self.assertIn("'sub' lives 90 days", str(caught.exception))

    def test_rejects_an_unknown_signer(self):
        with self.assertRaises(ValueError) as caught:
            helper.validate_cert_lifetimes(
                {
                    "certificates": [
                        {"id": "leaf", "certRole": "endentity", "signer": "typo",
                         "certParams": {"lifetimeDays": 1}},
                    ]
                }
            )
        self.assertIn("unknown certificate 'typo'", str(caught.exception))

    def test_rejects_a_duplicate_certificate_id(self):
        with self.assertRaises(ValueError) as caught:
            helper.validate_cert_lifetimes(
                {
                    "certificates": [
                        {"id": "root", "certRole": "root", "certParams": {"lifetimeDays": 10}},
                        {"id": "root", "certRole": "root", "certParams": {"lifetimeDays": 10}},
                    ]
                }
            )
        self.assertIn("duplicate certificate id", str(caught.exception))

    def test_rejects_a_missing_or_non_integer_lifetime(self):
        for lifetime in (None, 0, -1, "3650", 3650.0, True):
            with self.subTest(lifetime=lifetime):
                params = {} if lifetime is None else {"lifetimeDays": lifetime}
                with self.assertRaises(ValueError):
                    helper.validate_cert_lifetimes(
                        {"certificates": [{"id": "root", "certRole": "root", "certParams": params}]}
                    )

    def test_rejects_a_template_without_a_certificates_list(self):
        for template in ({}, {"certificates": {}}, {"certificates": "root"}):
            with self.subTest(template=template):
                with self.assertRaises(ValueError):
                    helper.validate_cert_lifetimes(template)


class RunValidateTemplateTest(unittest.TestCase):
    def test_exit_zero_for_the_shipped_template(self):
        self.assertEqual(helper.run_validate_template(TEMPLATE_PATH), 0)

    def test_exit_one_for_a_template_with_an_orphaned_certificate(self):
        regressed = _set_lifetime(_template(), "subroot", 90)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "cert-gen-config-template.yaml"
            path.write_text(yaml.dump(regressed, sort_keys=False), encoding="utf-8")
            self.assertEqual(helper.run_validate_template(path), 1)

    def test_exit_one_for_a_missing_template(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(helper.run_validate_template(Path(tmp) / "absent.yaml"), 1)


if __name__ == "__main__":
    unittest.main()
