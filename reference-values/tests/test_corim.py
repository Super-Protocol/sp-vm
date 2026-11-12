import base64
import unittest

from spref import CORIM_PROFILE, corim
from tests.test_evidence import azure_bundle, tdx_bundle
from spref import evidence

MANIFEST = {
    "build": "build-448-release",
    "artifacts": {
        "image": {
            "sha256": "65" * 32,
            "uncompressed_sha256": "5d" * 32,
        },
        "kernel": {"sha256": "a7" * 32},
        "bios": {"sha256": "0b" * 32},
        "bios_amd": {"sha256": "7f" * 32},
        "bios_tdx": {"sha256": "82" * 32},
    },
    "rootfs": {"verity_root_hash_sha256": "03" * 32},
    "platforms": {
        "sev-snp": {
            "cmdline_profiles": {
                "sp-vm-tools": {
                    "kernel_cmdline_sha256": "2c" * 32,
                    "launch_digest_sha384": "0c" * 48,
                    "mrenclave_sha256": "c9" * 32,
                }
            }
        }
    },
}


def _registers(triple):
    return triple["measurements"][0]["value"]["integrity-registers"]


def _only(triples, model):
    matches = [t for t in triples if t["environment"]["class"]["model"] == model]
    assert len(matches) == 1, f"{model}: {len(matches)} triples"
    return matches[0]


class ArtifactTripleTest(unittest.TestCase):
    def test_publishes_every_artifact_digest(self):
        triple = corim.artifact_triple(MANIFEST)
        self.assertEqual(triple["environment"]["class"]["model"], "sp-vm")
        self.assertEqual(
            sorted(_registers(triple)),
            [
                "bios",
                "bios-amd",
                "bios-tdx",
                "image",
                "image-uncompressed",
                "kernel",
                "rootfs-verity-root-hash",
            ],
        )

    def test_digests_are_sha256_base64(self):
        register = _registers(corim.artifact_triple(MANIFEST))["kernel"]
        self.assertEqual(register["key-type"], "text")
        algorithm, value = register["value"][0].split(";")
        self.assertEqual(algorithm, "sha-256")
        self.assertEqual(base64.b64decode(value), bytes.fromhex("a7" * 32))

    def test_measurement_version_is_the_build(self):
        value = corim.artifact_triple(MANIFEST)["measurements"][0]["value"]
        self.assertEqual(value["version"], {"value": "build-448-release", "scheme": "alphanumeric"})


class PlatformTripleTest(unittest.TestCase):
    def test_one_environment_per_cmdline_profile(self):
        manifest = dict(MANIFEST)
        manifest["platforms"] = {
            "sev-snp": {
                "cmdline_profiles": {
                    name: MANIFEST["platforms"]["sev-snp"]["cmdline_profiles"]["sp-vm-tools"]
                    for name in ("sp-vm-tools", "openstack-magnum")
                }
            }
        }
        models = [
            triple["environment"]["class"]["model"] for triple in corim.platform_triples(manifest)
        ]
        self.assertEqual(
            models, ["sp-vm-sev-snp:openstack-magnum", "sp-vm-sev-snp:sp-vm-tools"]
        )

    def test_launch_digest_is_sha384(self):
        triple = _only(corim.platform_triples(MANIFEST), "sp-vm-sev-snp:sp-vm-tools")
        self.assertTrue(_registers(triple)["launch-digest"]["value"][0].startswith("sha-384;"))
        self.assertTrue(_registers(triple)["mrenclave"]["value"][0].startswith("sha-256;"))

    def test_tdx_registers_and_td_attributes(self):
        manifest = dict(MANIFEST)
        section = evidence.verify_and_normalize("vector.json", tdx_bundle())
        manifest["platforms"] = {"tdx": section}
        triple = _only(corim.platform_triples(manifest), "sp-vm-tdx")
        self.assertEqual(
            sorted(_registers(triple)),
            ["mrenclave", "mrtd", "rtmr0", "rtmr0-normalized", "rtmr1", "rtmr2", "rtmr3"],
        )
        raw = triple["measurements"][0]["value"]["raw-value"]
        self.assertEqual(raw["type"], "bytes")
        self.assertEqual(base64.b64decode(raw["value"]).hex(), section["td_attributes"])

    def test_azure_flags_use_the_mrenclave_order(self):
        manifest = dict(MANIFEST)
        section = evidence.verify_and_normalize("vector.json", azure_bundle("tdx-azure"))
        manifest["platforms"] = {"tdx-azure": section}
        triple = _only(corim.platform_triples(manifest), "sp-vm-tdx-azure")
        flags = base64.b64decode(triple["measurements"][0]["value"]["raw-value"]["value"])
        expected = bytes(
            1 if section["vm_configuration"][name] else 0
            for name in evidence.AZURE_FLAGS["tdx-azure"]
        )
        self.assertEqual(flags, expected)
        self.assertNotEqual(
            flags,
            bytes(1 if value else 0 for _, value in sorted(section["vm_configuration"].items())),
            "the test vector must distinguish the documented order from the alphabetical one",
        )

    def test_rejects_an_unmapped_platform(self):
        manifest = dict(MANIFEST)
        manifest["platforms"] = {"risc-v-cove": {}}
        with self.assertRaises(corim.CorimError):
            corim.platform_triples(manifest)


class TemplateTest(unittest.TestCase):
    def test_tag_and_environment_ids_are_stable(self):
        first = corim.comid_template(MANIFEST)
        second = corim.comid_template(MANIFEST)
        self.assertEqual(first, second)
        self.assertEqual(
            first["tag-identity"]["id"], corim.comid_template(MANIFEST)["tag-identity"]["id"]
        )

    def test_a_different_build_gets_a_different_tag_id(self):
        other = dict(MANIFEST, build="build-449-release")
        self.assertNotEqual(
            corim.comid_template(MANIFEST)["tag-identity"]["id"],
            corim.comid_template(other)["tag-identity"]["id"],
        )

    def test_corim_template_carries_the_profile_and_validity(self):
        template = corim.corim_template(MANIFEST, "2026-11-12T00:00:00Z", "2036-11-12T00:00:00Z")
        self.assertEqual(template["profiles"], [CORIM_PROFILE])
        self.assertEqual(template["validity"]["not-before"], "2026-11-12T00:00:00Z")
        self.assertEqual(template["entities"][0]["roles"], ["manifestCreator"])

    def test_json_document_embeds_the_manifest_and_the_tag(self):
        comid = corim.comid_template(MANIFEST)
        corim_t = corim.corim_template(MANIFEST, "2026-11-12T00:00:00Z", "2036-11-12T00:00:00Z")
        meta = corim.meta_template("signer", "2026-11-12T00:00:00Z", "2036-11-12T00:00:00Z")
        document = corim.json_document(MANIFEST, comid, corim_t, meta)
        self.assertEqual(document["corim"]["tags"], [comid])
        self.assertEqual(document["reference_values"], MANIFEST)
        self.assertEqual(document["meta"]["signer"]["name"], "signer")


if __name__ == "__main__":
    unittest.main()
