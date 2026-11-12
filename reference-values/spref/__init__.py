"""Reference Values generator for sp-vm releases (SUP-640).

Turns the output of a reproducible sp-vm build into the signed, standard
Reference Values that an external Verifier (Intel Trust Authority appraisal
policy, Veraison endorsements) can use without trusting Super Protocol's own
PKI.

See ../README.md for the format, the publication procedure and the
"rebuild and measure yourself" instructions.
"""

VERSION = "1.0.0"

MANIFEST_SCHEMA = "https://superprotocol.com/schemas/sp-vm-reference-values/1"
EVIDENCE_SCHEMA = "https://superprotocol.com/schemas/sp-vm-reference-evidence/1"
CORIM_PROFILE = "https://superprotocol.com/corim/sp-vm/1"

# Namespace UUID (RFC 4122 v5) under which every sp-vm CoRIM/CoMID tag id and
# the environment class id are derived, so that the ids are stable across
# regenerations of the same release.
NAMESPACE_UUID = "1b4e2b2e-0e0c-5a9e-9f1a-2a3f0d9a7c51"
