import copy
import hashlib
import json
import os
import tempfile
import unittest

from spref import artifacts, manifest

VM_JSON = {
    "image": {
        "bucket": "builds-vm",
        "prefix": "build-448-release",
        "filename": "sp-vm-build-448-release.img.zst",
        "sha256": "65" * 32,
        "compression": "zstd",
        "uncompressed_filename": "sp-vm-build-448-release.img",
        "uncompressed_sha256": "5d" * 32,
        "uncompressed_size": 4478468096,
    },
    "kernel": {"bucket": "builds-vm", "prefix": "build-448-release", "filename": "vmlinuz", "sha256": "a7" * 32},
    "bios": {"bucket": "builds-vm", "prefix": "build-448-release", "filename": "OVMF.fd", "sha256": "0b" * 32},
    "bios_amd": {"bucket": "builds-vm", "prefix": "build-448-release", "filename": "OVMF_AMD.fd", "sha256": "7f" * 32},
    "bios_tdx": {"bucket": "builds-vm", "prefix": "build-448-release", "filename": "OVMF_TDX.fd", "sha256": "82" * 32},
    "rootfs_hash": {"bucket": "builds-vm", "prefix": "build-448-release", "filename": "rootfs_hash.txt", "sha256": "18" * 32},
}
ROOTFS_HASH = "03" * 32


class ArtifactDir:
    """A build output directory: vm.json, rootfs_hash.txt and optional files."""

    def __init__(self, vm_json=None, rootfs_hash=ROOTFS_HASH, files=None):
        self.tmp = tempfile.TemporaryDirectory()
        vm_json = copy.deepcopy(VM_JSON if vm_json is None else vm_json)

        if rootfs_hash is not None:
            content = (rootfs_hash + "\n").encode("ascii")
            with open(os.path.join(self.tmp.name, "rootfs_hash.txt"), "wb") as handle:
                handle.write(content)
            # Keep vm.json honest about the file that is actually written, so
            # the digest check under test is exercised by the other fixtures.
            if "rootfs_hash" in vm_json:
                vm_json["rootfs_hash"]["sha256"] = hashlib.sha256(content).hexdigest()

        with open(os.path.join(self.tmp.name, "vm.json"), "w", encoding="utf-8") as handle:
            json.dump(vm_json, handle)
        for name, content in (files or {}).items():
            with open(os.path.join(self.tmp.name, name), "wb") as handle:
                handle.write(content)

    @property
    def path(self):
        return self.tmp.name


class ArtifactsTest(unittest.TestCase):
    def test_collects_every_published_artifact(self):
        directory = ArtifactDir()
        self.addCleanup(directory.tmp.cleanup)
        collected = artifacts.collect(directory.path)
        self.assertEqual(sorted(collected["artifacts"]), sorted(artifacts.ARTIFACT_KEYS))
        self.assertEqual(collected["rootfs"]["verity_root_hash_sha256"], ROOTFS_HASH)
        self.assertEqual(collected["artifacts"]["image"]["uncompressed_size"], 4478468096)

    def test_rejects_a_missing_artifact_entry(self):
        vm_json = {key: value for key, value in VM_JSON.items() if key != "bios_tdx"}
        directory = ArtifactDir(vm_json=vm_json)
        self.addCleanup(directory.tmp.cleanup)
        with self.assertRaises(artifacts.ArtifactError) as raised:
            artifacts.collect(directory.path)
        self.assertIn("bios_tdx", str(raised.exception))

    def test_rejects_an_unknown_artifact_entry(self):
        vm_json = dict(VM_JSON, initrd={"bucket": "b", "prefix": "p", "filename": "initrd", "sha256": "11" * 32})
        directory = ArtifactDir(vm_json=vm_json)
        self.addCleanup(directory.tmp.cleanup)
        with self.assertRaises(artifacts.ArtifactError) as raised:
            artifacts.collect(directory.path)
        self.assertIn("initrd", str(raised.exception))

    def test_rejects_an_artifact_that_disagrees_with_vm_json(self):
        directory = ArtifactDir(files={"vmlinuz": b"not the kernel vm.json describes"})
        self.addCleanup(directory.tmp.cleanup)
        with self.assertRaises(artifacts.ArtifactError) as raised:
            artifacts.collect(directory.path)
        self.assertIn("vmlinuz", str(raised.exception))

    def test_trusts_vm_json_when_verification_is_off(self):
        directory = ArtifactDir(files={"vmlinuz": b"not the kernel vm.json describes"})
        self.addCleanup(directory.tmp.cleanup)
        collected = artifacts.collect(directory.path, verify_digests=False)
        self.assertEqual(collected["artifacts"]["kernel"]["sha256"], "a7" * 32)

    def test_rejects_a_malformed_rootfs_hash(self):
        directory = ArtifactDir(rootfs_hash="not-a-hash")
        self.addCleanup(directory.tmp.cleanup)
        with self.assertRaises(artifacts.ArtifactError):
            artifacts.collect(directory.path)


class CmdlineProfileTest(unittest.TestCase):
    def test_reads_the_repository_profiles(self):
        profiles = manifest.load_cmdline_profiles()
        self.assertIn("openstack-magnum", profiles)
        self.assertIn("sp-vm-tools", profiles)
        for name, template in profiles.items():
            self.assertIn("{build}", template, name)
            self.assertIn("{rootfs_verity_hash}", template, name)

    def test_the_published_profiles_are_distinct(self):
        profiles = manifest.load_cmdline_profiles()
        rendered = {
            template.format(build="build-1", rootfs_verity_hash="00" * 32)
            for template in profiles.values()
        }
        self.assertEqual(len(rendered), len(profiles))

    def test_ignores_comments(self):
        with tempfile.TemporaryDirectory() as root:
            with open(os.path.join(root, "x.cmdline"), "w", encoding="utf-8") as handle:
                handle.write("# a comment\n\nroot=LABEL=rootfs build={build}\n")
            self.assertEqual(
                manifest.load_cmdline_profiles(root), {"x": "root=LABEL=rootfs build={build}"}
            )

    def test_rejects_a_profile_with_two_command_lines(self):
        with tempfile.TemporaryDirectory() as root:
            with open(os.path.join(root, "x.cmdline"), "w", encoding="utf-8") as handle:
                handle.write("one\ntwo\n")
            with self.assertRaises(manifest.ManifestError):
                manifest.load_cmdline_profiles(root)

    def test_rejects_an_empty_directory(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(manifest.ManifestError):
                manifest.load_cmdline_profiles(root)


class BuildManifestTest(unittest.TestCase):
    def test_rejects_a_build_that_vm_json_does_not_describe(self):
        directory = ArtifactDir()
        self.addCleanup(directory.tmp.cleanup)
        with self.assertRaises(manifest.ManifestError) as raised:
            manifest.build("build-449-release", directory.path)
        self.assertIn("build-448-release", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
