"""COSE_Sign1 (RFC 9052) verification of a signed CoRIM."""

import base64
import json

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils as asym_utils

from .cbor import Tag, dumps, loads

COSE_SIGN1_TAG = 18
CORIM_SIGNED_TAG = 18  # a signed CoRIM is a tagged COSE_Sign1
HEADER_ALG = 1

# COSE algorithm -> (hash, expected EC curve name)
ES_ALGORITHMS = {
    -7: (hashes.SHA256, "secp256r1"),
    -35: (hashes.SHA384, "secp384r1"),
    -36: (hashes.SHA512, "secp521r1"),
}


class CoseError(Exception):
    pass


def _b64url(value, label):
    padding = "=" * (-len(value) % 4)
    try:
        return base64.urlsafe_b64decode(value + padding)
    except Exception as exc:  # noqa: BLE001 - surfaced with context below
        raise CoseError(f"{label}: not valid base64url") from exc


def public_key_from_jwk(raw):
    """Load an EC public key from a JWK (the private half, if any, is ignored)."""
    try:
        jwk = json.loads(raw)
    except ValueError as exc:
        raise CoseError(f"not valid JSON: {exc}") from exc
    if jwk.get("kty") != "EC":
        raise CoseError(f"unsupported JWK key type {jwk.get('kty')!r}; expected EC")

    curves = {"P-256": ec.SECP256R1, "P-384": ec.SECP384R1, "P-521": ec.SECP521R1}
    curve = curves.get(jwk.get("crv"))
    if curve is None:
        raise CoseError(f"unsupported JWK curve {jwk.get('crv')!r}")

    x = _b64url(jwk["x"], "JWK x")
    y = _b64url(jwk["y"], "JWK y")
    numbers = ec.EllipticCurvePublicNumbers(
        int.from_bytes(x, "big"), int.from_bytes(y, "big"), curve()
    )
    return numbers.public_key()


def parse_sign1(data):
    """Return (protected_bstr, unprotected, payload, signature) of a COSE_Sign1."""
    item = loads(data)
    if isinstance(item, Tag):
        if item.number != COSE_SIGN1_TAG:
            raise CoseError(f"expected CBOR tag {COSE_SIGN1_TAG} (COSE_Sign1), got {item.number}")
        item = item.value
    if not isinstance(item, list) or len(item) != 4:
        raise CoseError("expected a COSE_Sign1 array of four items")

    protected, unprotected, payload, signature = item
    for label, value in (("protected", protected), ("payload", payload), ("signature", signature)):
        if not isinstance(value, bytes):
            raise CoseError(f"COSE_Sign1 {label} must be a byte string")
    if not isinstance(unprotected, dict):
        raise CoseError("COSE_Sign1 unprotected header must be a map")
    return protected, unprotected, payload, signature


def verify_sign1(data, public_key, external_aad=b""):
    """Verify a COSE_Sign1 and return its payload."""
    protected, _, payload, signature = parse_sign1(data)

    headers = loads(protected) if protected else {}
    if not isinstance(headers, dict):
        raise CoseError("COSE_Sign1 protected header must be a map")
    alg = headers.get(HEADER_ALG)
    if alg not in ES_ALGORITHMS:
        raise CoseError(f"unsupported COSE algorithm {alg!r}; expected one of {sorted(ES_ALGORITHMS)}")

    hash_cls, curve_name = ES_ALGORITHMS[alg]
    if not isinstance(public_key, ec.EllipticCurvePublicKey):
        raise CoseError("an EC public key is required")
    if public_key.curve.name != curve_name:
        raise CoseError(
            f"the CoRIM is signed with {curve_name} (COSE alg {alg}), "
            f"but the key is on {public_key.curve.name}"
        )

    sig_structure = dumps(["Signature1", protected, external_aad, payload])

    size = (public_key.curve.key_size + 7) // 8
    if len(signature) != 2 * size:
        raise CoseError(f"signature is {len(signature)} bytes, expected {2 * size}")
    der = asym_utils.encode_dss_signature(
        int.from_bytes(signature[:size], "big"), int.from_bytes(signature[size:], "big")
    )

    try:
        public_key.verify(der, sig_structure, ec.ECDSA(hash_cls()))
    except InvalidSignature as exc:
        raise CoseError("the CoRIM signature does not verify with this key") from exc

    return payload
