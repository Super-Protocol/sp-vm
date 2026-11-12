#!/usr/bin/env python3
"""Unit tests for the cert-gen template guard in pki_configure_helper.py (SUP-653).

The whole certificate chain is generated once, on the bootstrap node, and nothing
renews it. A subordinate certificate configured to live longer than its signer is
therefore orphaned before it expires, which is how the 90-day subroots silently put a
cliff 90 days after every bootstrap. `validate_cert_lifetimes` makes that shape a
hard error, and this suite pins both the shipped template and the failure modes.

    cd src/rootfs/tests && python3 -m unittest test_pki_configure_helper -v
"""

import copy
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent.parent
HELPER_PATH = (
    REPO_ROOT / "src/rootfs/files/configs/pki-service/scripts/pki_configure_helper.py"
)
TEMPLATE_PATH = (
    REPO_ROOT / "src/rootfs/files/configs/pki-service/conf/cert-gen-config-template.yaml"
)


def _load_helper():
    spec = importlib.util.spec_from_file_location("pki_configure_helper", HELPER_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


helper = _load_helper()
yaml = helper.yaml


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
