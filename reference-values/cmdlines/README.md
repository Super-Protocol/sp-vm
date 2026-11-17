# Kernel command-line profiles

The AMD SEV-SNP launch digest covers the kernel command line, so a reference
value is only meaningful together with the command line the VM was started
with. Each `*.cmdline` file here is one command line that Super Protocol
publishes a launch digest for; the generator emits one CoMID reference-value
triple per profile (`sp-vm-sev-snp:<profile>`).

Placeholders, substituted per release:

| Placeholder             | Value                                              |
|-------------------------|----------------------------------------------------|
| `{build}`               | the build id, e.g. `build-448-release`             |
| `{rootfs_verity_hash}`  | the dm-verity root hash from `rootfs_hash.txt`     |

A file holds exactly one command line; `#` comment lines are ignored.

An operator that starts sp-vm with any other command line gets a different
launch digest and must compute it themselves — see the "Operators with a
different kernel command line" section of `../README.md`.
