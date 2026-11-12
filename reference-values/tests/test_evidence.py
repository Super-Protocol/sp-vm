import copy
import hashlib
import json
import os
import tempfile
import unittest

from spref import EVIDENCE_SCHEMA, evidence


def _digest48(seed):
    return hashlib.sha384(seed).digest()


def _digest32(seed):
    return hashlib.sha256(seed).digest()


def tdx_bundle():
    """A self-consistent tdx bundle: RTMR0 and mrEnclave are derived, not typed."""
    event_log = [
        {"type": "EV_EFI_PLATFORM_FIRMWARE_BLOB2", "digest": _digest48(b"fw-volume-1").hex()},
        {"type": "EV_EFI_PLATFORM_FIRMWARE_BLOB2", "digest": _digest48(b"fw-volume-2").hex()},
        {"type": "EV_EFI_HANDOFF_TABLES2", "digest": _digest48(b"handoff").hex()},
        {"type": "EV_SEPARATOR", "digest": _digest48(b"separator").hex()},
    ]
    rtmr0 = evidence.rtmr_replay([bytes.fromhex(entry["digest"]) for entry in event_log])
    rtmr0_normalized = evidence.rtmr_replay(
        [bytes.fromhex(entry["digest"]) for entry in event_log[:2]]
    )
    td_attributes = bytes.fromhex("0000001000000000")
    mrtd = _digest48(b"mrtd")
    rtmr1, rtmr2, rtmr3 = _digest48(b"rtmr1"), _digest48(b"rtmr2"), _digest48(b"rtmr3")

    return {
        "schema": EVIDENCE_SCHEMA,
        "build": "build-456-release",
        "platform": "tdx",
        "collected_at": "2026-10-22T16:58:55Z",
        "collected_on": "synthetic test vector",
        "mrenclave": evidence.tdx_mrenclave(
            td_attributes, mrtd, rtmr0_normalized, rtmr1, rtmr2, rtmr3
        ),
        "tdx": {
            "td_attributes": td_attributes.hex(),
            "mrtd": mrtd.hex(),
            "rtmr0": rtmr0.hex(),
            "rtmr1": rtmr1.hex(),
            "rtmr2": rtmr2.hex(),
            "rtmr3": rtmr3.hex(),
            "rtmr0_event_log": event_log,
        },
    }


def azure_bundle(platform="tdx-azure"):
    separator_data = bytes.fromhex("00000000")
    event_log = [
        {"pcr": 4, "type": "EV_NO_ACTION", "digest": _digest32(b"spec-id").hex()},
        {"pcr": 4, "type": "EV_EFI_BOOT_SERVICES_APPLICATION", "digest": _digest32(b"shim").hex()},
        {
            "pcr": 4,
            "type": "EV_SEPARATOR",
            "digest": hashlib.sha256(separator_data).hexdigest(),
            "data": separator_data.hex(),
        },
        {"pcr": 9, "type": "EV_EFI_VARIABLE_BOOT", "digest": _digest32(b"cmdline").hex()},
    ]
    pcr4 = evidence.pcr_replay([_digest32(b"shim")])
    pcr9 = evidence.pcr_replay([_digest32(b"cmdline")])
    vm_configuration = {name: index % 2 == 0 for index, name in enumerate(evidence.AZURE_FLAGS[platform])}

    return {
        "schema": EVIDENCE_SCHEMA,
        "build": "build-456-release",
        "platform": platform,
        "collected_at": "2026-10-22T16:58:55Z",
        "collected_on": "synthetic test vector",
        "mrenclave": evidence.azure_mrenclave(platform, vm_configuration, pcr4, pcr9),
        "azure": {"vm_configuration": vm_configuration, "event_log": event_log},
    }


class ReplayTest(unittest.TestCase):
    def test_rtmr_replay_starts_from_48_zero_bytes(self):
        digest = bytes(48)
        self.assertEqual(
            evidence.rtmr_replay([digest]), hashlib.sha384(bytes(48) + digest).digest()
        )

    def test_rtmr_replay_is_a_chain(self):
        first, second = _digest48(b"a"), _digest48(b"b")
        expected = hashlib.sha384(hashlib.sha384(bytes(48) + first).digest() + second).digest()
        self.assertEqual(evidence.rtmr_replay([first, second]), expected)

    def test_pcr_replay_starts_from_32_zero_bytes(self):
        digest = _digest32(b"x")
        self.assertEqual(
            evidence.pcr_replay([digest]), hashlib.sha256(bytes(32) + digest).digest()
        )

    def test_empty_replay_is_the_zero_register(self):
        self.assertEqual(evidence.rtmr_replay([]), bytes(48))
        self.assertEqual(evidence.pcr_replay([]), bytes(32))


class TdxBundleTest(unittest.TestCase):
    def test_accepts_a_consistent_bundle(self):
        bundle = tdx_bundle()
        section = evidence.verify_and_normalize("vector.json", bundle)
        self.assertEqual(section["source"], "reference-boot-evidence")
        self.assertEqual(section["mrtd"], bundle["tdx"]["mrtd"])
        self.assertEqual(section["rtmr0"], bundle["tdx"]["rtmr0"])
        # The normalised RTMR0 keeps only the two firmware-blob events.
        self.assertNotEqual(section["rtmr0_normalized"], section["rtmr0"])
        self.assertEqual(
            section["rtmr0_normalized"],
            evidence.rtmr_replay(
                [bytes.fromhex(entry["digest"]) for entry in bundle["tdx"]["rtmr0_event_log"][:2]]
            ).hex(),
        )

    def test_rejects_an_event_log_that_does_not_reproduce_rtmr0(self):
        bundle = tdx_bundle()
        bundle["tdx"]["rtmr0_event_log"].pop()
        with self.assertRaises(evidence.EvidenceError) as raised:
            evidence.verify_and_normalize("vector.json", bundle)
        self.assertIn("rtmr0", str(raised.exception))

    def test_rejects_a_register_that_does_not_reproduce_mrenclave(self):
        bundle = tdx_bundle()
        bundle["tdx"]["rtmr1"] = _digest48(b"tampered").hex()
        with self.assertRaises(evidence.EvidenceError) as raised:
            evidence.verify_and_normalize("vector.json", bundle)
        self.assertIn("mrEnclave recomputed", str(raised.exception))

    def test_rejects_an_event_log_without_a_firmware_blob_event(self):
        bundle = tdx_bundle()
        for entry in bundle["tdx"]["rtmr0_event_log"]:
            entry["type"] = "EV_EFI_HANDOFF_TABLES2"
        bundle["tdx"]["rtmr0"] = evidence.rtmr_replay(
            [bytes.fromhex(entry["digest"]) for entry in bundle["tdx"]["rtmr0_event_log"]]
        ).hex()
        with self.assertRaises(evidence.EvidenceError) as raised:
            evidence.verify_and_normalize("vector.json", bundle)
        self.assertIn("EV_EFI_PLATFORM_FIRMWARE_BLOB", str(raised.exception))

    def test_rejects_a_register_of_the_wrong_size(self):
        bundle = tdx_bundle()
        bundle["tdx"]["mrtd"] = _digest32(b"too short").hex()
        with self.assertRaises(ValueError):
            evidence.verify_and_normalize("vector.json", bundle)

    def test_rejects_a_missing_field(self):
        bundle = tdx_bundle()
        del bundle["tdx"]["rtmr2"]
        with self.assertRaises(evidence.EvidenceError) as raised:
            evidence.verify_and_normalize("vector.json", bundle)
        self.assertIn("rtmr2", str(raised.exception))


class AzureBundleTest(unittest.TestCase):
    def test_accepts_a_consistent_bundle(self):
        bundle = azure_bundle()
        section = evidence.verify_and_normalize("vector.json", bundle)
        self.assertEqual(
            sorted(section["vm_configuration"]), sorted(evidence.AZURE_FLAGS["tdx-azure"])
        )
        self.assertEqual(len(section["pcr4_normalized"]), 64)
        self.assertEqual(len(section["pcr9_normalized"]), 64)

    def test_sev_snp_azure_has_three_flags(self):
        section = evidence.verify_and_normalize("vector.json", azure_bundle("sev-snp-azure"))
        self.assertEqual(len(section["vm_configuration"]), 3)

    def test_flag_order_changes_mrenclave(self):
        flags = evidence.AZURE_FLAGS["tdx-azure"]
        pcr4, pcr9 = bytes(32), bytes(32)
        straight = evidence.azure_mrenclave(
            "tdx-azure", {name: index == 0 for index, name in enumerate(flags)}, pcr4, pcr9
        )
        reversed_ = evidence.azure_mrenclave(
            "tdx-azure",
            {name: index == len(flags) - 1 for index, name in enumerate(flags)},
            pcr4,
            pcr9,
        )
        self.assertNotEqual(straight, reversed_)

    def test_rejects_a_missing_flag(self):
        bundle = azure_bundle()
        del bundle["azure"]["vm_configuration"]["tpm-enabled"]
        with self.assertRaises(evidence.EvidenceError) as raised:
            evidence.verify_and_normalize("vector.json", bundle)
        self.assertIn("tpm-enabled", str(raised.exception))

    def test_rejects_a_non_boolean_flag(self):
        bundle = azure_bundle()
        bundle["azure"]["vm_configuration"]["tpm-enabled"] = "true"
        with self.assertRaises(evidence.EvidenceError):
            evidence.verify_and_normalize("vector.json", bundle)

    def test_rejects_an_unexpected_pcr(self):
        bundle = azure_bundle()
        bundle["azure"]["event_log"].append(
            {"pcr": 7, "type": "EV_EFI_VARIABLE_DRIVER_CONFIG", "digest": _digest32(b"sb").hex()}
        )
        with self.assertRaises(evidence.EvidenceError) as raised:
            evidence.verify_and_normalize("vector.json", bundle)
        self.assertIn("PCR7", str(raised.exception))

    def test_a_separator_that_does_not_describe_itself_is_measured(self):
        bundle = azure_bundle()
        tampered = copy.deepcopy(bundle)
        for entry in tampered["azure"]["event_log"]:
            if entry["type"] == "EV_SEPARATOR":
                entry["digest"] = _digest32(b"not the event data").hex()
        # The separator is now measured, so PCR4' and mrEnclave change.
        with self.assertRaises(evidence.EvidenceError):
            evidence.verify_and_normalize("vector.json", tampered)

    def test_rejects_a_separator_without_event_data(self):
        bundle = azure_bundle()
        for entry in bundle["azure"]["event_log"]:
            entry.pop("data", None)
        with self.assertRaises(evidence.EvidenceError) as raised:
            evidence.verify_and_normalize("vector.json", bundle)
        self.assertIn("event data", str(raised.exception))


class DiscoveryTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.addCleanup(self.root.cleanup)
        self.build_dir = os.path.join(self.root.name, "build-456-release")
        os.makedirs(self.build_dir)

    def _write(self, name, bundle):
        path = os.path.join(self.build_dir, name)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(bundle, handle)
        return path

    def test_finds_one_bundle_per_platform(self):
        self._write("tdx.json", tdx_bundle())
        self._write("tdx-azure.json", azure_bundle())
        found = evidence.discover(self.root.name, "build-456-release")
        self.assertEqual(sorted(found), ["tdx", "tdx-azure"])

    def test_missing_build_directory_is_not_an_error(self):
        self.assertEqual(evidence.discover(self.root.name, "build-999-release"), {})

    def test_rejects_two_bundles_for_one_platform(self):
        self._write("tdx.json", tdx_bundle())
        self._write("tdx-copy.json", tdx_bundle())
        with self.assertRaises(evidence.EvidenceError):
            evidence.discover(self.root.name, "build-456-release")

    def test_rejects_a_bundle_for_another_build(self):
        bundle = tdx_bundle()
        bundle["build"] = "build-455-release"
        self._write("tdx.json", bundle)
        with self.assertRaises(evidence.EvidenceError) as raised:
            evidence.discover(self.root.name, "build-456-release")
        self.assertIn("build-455-release", str(raised.exception))

    def test_rejects_an_unknown_schema(self):
        bundle = tdx_bundle()
        bundle["schema"] = "https://example.com/other/1"
        path = self._write("tdx.json", bundle)
        with self.assertRaises(evidence.EvidenceError):
            evidence.load_bundle(path)

    def test_rejects_an_unknown_platform(self):
        bundle = tdx_bundle()
        bundle["platform"] = "sev-snp"
        path = self._write("snp.json", bundle)
        with self.assertRaises(evidence.EvidenceError) as raised:
            evidence.load_bundle(path)
        self.assertIn("unknown platform", str(raised.exception))


if __name__ == "__main__":
    unittest.main()


class CommittedExampleTest(unittest.TestCase):
    """The example bundles in the documentation must be self-consistent."""

    EXAMPLES = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "evidence"
    )

    def test_examples_verify(self):
        found = 0
        for name in sorted(os.listdir(self.EXAMPLES)):
            if not name.startswith("example-") or not name.endswith(".json"):
                continue
            path = os.path.join(self.EXAMPLES, name)
            section = evidence.verify_and_normalize(path, evidence.load_bundle(path))
            self.assertEqual(section["source"], "reference-boot-evidence")
            found += 1
        self.assertGreater(found, 0, "no example bundle found next to the schema")

    def test_examples_are_not_mistaken_for_a_real_release(self):
        for name in sorted(os.listdir(self.EXAMPLES)):
            if not name.startswith("example-"):
                continue
            bundle = evidence.load_bundle(os.path.join(self.EXAMPLES, name))
            self.assertEqual(bundle["build"], "build-000-example")
            self.assertIn("EXAMPLE ONLY", bundle["collected_on"])


class BundleFieldTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.addCleanup(self.root.cleanup)

    def _path(self, bundle):
        path = os.path.join(self.root.name, "bundle.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(bundle, handle)
        return path

    def test_rejects_a_bundle_without_provenance(self):
        bundle = tdx_bundle()
        del bundle["collected_on"]
        with self.assertRaises(evidence.EvidenceError) as raised:
            evidence.load_bundle(self._path(bundle))
        self.assertIn("collected_on", str(raised.exception))

    def test_rejects_an_mrenclave_of_the_wrong_size(self):
        bundle = tdx_bundle()
        bundle["mrenclave"] = "ab" * 48
        with self.assertRaises(ValueError):
            evidence.load_bundle(self._path(bundle))

    def test_rejects_a_file_that_is_not_json(self):
        path = os.path.join(self.root.name, "broken.json")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("{not json")
        with self.assertRaises(evidence.EvidenceError):
            evidence.load_bundle(path)
