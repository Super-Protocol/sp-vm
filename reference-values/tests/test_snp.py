import os
import unittest
from unittest import mock

from spref import snp


class CpuSignatureTest(unittest.TestCase):
    def test_milan_signature(self):
        # AMD EPYC Milan reports CPUID family 25, model 1, stepping 1, which
        # encodes to 0x00a00f11.
        self.assertEqual(snp.MILAN_SIG, 0x00A00F11)

    def test_extended_family_and_model_are_split(self):
        # Genoa: family 25 -> extended family 10, model 17 -> model 0x1/0x1.
        self.assertEqual(snp.cpu_sig(25, 17, 0), 0x00A10F10)
        # A family below 15 is encoded without an extended part.
        self.assertEqual(snp.cpu_sig(6, 2, 3), 0x00000623)


class CmdlineHashTest(unittest.TestCase):
    def test_command_line_is_nul_terminated(self):
        import hashlib

        cmdline = "root=LABEL=rootfs"
        self.assertEqual(
            snp.cmdline_sha256(cmdline),
            hashlib.sha256(cmdline.encode() + b"\x00").hexdigest(),
        )
        self.assertNotEqual(
            snp.cmdline_sha256(cmdline), hashlib.sha256(cmdline.encode()).hexdigest()
        )


class MrEnclaveTest(unittest.TestCase):
    # Launch digest of sp-vm build-448-release, normalised to one EPYC Milan
    # vCPU, as computed by sev-snp-measure from OVMF_AMD.fd, vmlinuz and the
    # openstack-magnum kernel command line.
    BUILD_448_LAUNCH_DIGEST = bytes.fromhex(
        "0c923b74aed3fe7e94af6106d54d1aff1b80adf2838d0cda92eda2f3900efb8c"
        "a581cf44906cfd820681f8ebc9777285"
    )
    # The mrEnclave Super Protocol signed for build-448-release:
    # signatures/sev-snp/latest/mrenclave-c9e1....json.
    BUILD_448_MRENCLAVE = "c9e148780ef1aa945a2b8578926dc9faaf1fc37038bce04e9613037f1fe42442"

    def test_reproduces_the_published_build_448_mrenclave(self):
        self.assertEqual(snp.mrenclave(self.BUILD_448_LAUNCH_DIGEST), self.BUILD_448_MRENCLAVE)

    def test_vmpl_and_policy_are_part_of_the_wrapper(self):
        self.assertNotEqual(
            snp.mrenclave(self.BUILD_448_LAUNCH_DIGEST, vmpl=1), self.BUILD_448_MRENCLAVE
        )
        self.assertNotEqual(
            snp.mrenclave(self.BUILD_448_LAUNCH_DIGEST, policy=0x30001),
            self.BUILD_448_MRENCLAVE,
        )

    def test_rejects_a_digest_of_the_wrong_length(self):
        with self.assertRaises(snp.SnpError):
            snp.mrenclave(bytes(32))


class LaunchDigestTest(unittest.TestCase):
    def test_reports_a_missing_tool(self):
        with mock.patch.dict(os.environ, {"PATH": "", "SEV_SNP_MEASURE": ""}):
            with self.assertRaises(snp.SnpError) as raised:
                snp.launch_digest("ovmf", "kernel", "cmdline")
        self.assertIn("sev-snp-measure not found", str(raised.exception))

    def test_reports_missing_inputs(self):
        with self.assertRaises(snp.SnpError) as raised:
            snp.launch_digest("/nonexistent/ovmf", "/nonexistent/kernel", "cmdline",
                              sev_snp_measure="/bin/true")
        self.assertIn("OVMF not found", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
