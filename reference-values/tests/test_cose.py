import base64
import json
import unittest

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils as asym_utils

from spref import cbor, cose

# map(1){1: alg}
PROTECTED_ES384 = bytes.fromhex("a1013822")
PROTECTED_ES256 = bytes.fromhex("a10126")
PROTECTED_UNKNOWN_ALG = bytes.fromhex("a1012f")  # alg -16, not a COSE signature alg


def _jwk(key, private=False):
    numbers = key.public_key().public_numbers()
    size = (key.curve.key_size + 7) // 8
    url = lambda value: base64.urlsafe_b64encode(value.to_bytes(size, "big")).rstrip(b"=").decode()
    jwk = {
        "kty": "EC",
        "crv": {256: "P-256", 384: "P-384"}[key.curve.key_size],
        "x": url(numbers.x),
        "y": url(numbers.y),
    }
    if private:
        jwk["d"] = url(key.private_numbers().private_value)
    return json.dumps(jwk)


def _sign1(key, payload, protected=PROTECTED_ES384, hash_cls=hashes.SHA384, tagged=True):
    sig_structure = cbor.dumps(["Signature1", protected, b"", payload])
    der = key.sign(sig_structure, ec.ECDSA(hash_cls()))
    r, s = asym_utils.decode_dss_signature(der)
    size = (key.curve.key_size + 7) // 8
    signature = r.to_bytes(size, "big") + s.to_bytes(size, "big")
    envelope = (
        b"\x84" + cbor.dumps(protected) + b"\xa0" + cbor.dumps(payload) + cbor.dumps(signature)
    )
    return (b"\xd2" if tagged else b"") + envelope


class PublicKeyFromJwkTest(unittest.TestCase):
    def test_loads_a_public_key(self):
        key = ec.generate_private_key(ec.SECP384R1())
        loaded = cose.public_key_from_jwk(_jwk(key))
        self.assertEqual(
            loaded.public_numbers(), key.public_key().public_numbers()
        )

    def test_ignores_the_private_half(self):
        key = ec.generate_private_key(ec.SECP384R1())
        loaded = cose.public_key_from_jwk(_jwk(key, private=True))
        self.assertIsInstance(loaded, ec.EllipticCurvePublicKey)

    def test_rejects_a_non_ec_key(self):
        with self.assertRaises(cose.CoseError):
            cose.public_key_from_jwk('{"kty":"RSA","n":"AQAB","e":"AQAB"}')

    def test_rejects_an_unknown_curve(self):
        with self.assertRaises(cose.CoseError):
            cose.public_key_from_jwk('{"kty":"EC","crv":"P-192","x":"AA","y":"AA"}')

    def test_rejects_invalid_json(self):
        with self.assertRaises(cose.CoseError):
            cose.public_key_from_jwk("not json")


class VerifySign1Test(unittest.TestCase):
    def setUp(self):
        self.key = ec.generate_private_key(ec.SECP384R1())
        self.public = self.key.public_key()
        self.payload = b"a CoRIM payload"
        self.signed = _sign1(self.key, self.payload)

    def test_verifies_and_returns_the_payload(self):
        self.assertEqual(cose.verify_sign1(self.signed, self.public), self.payload)

    def test_accepts_an_untagged_envelope(self):
        untagged = _sign1(self.key, self.payload, tagged=False)
        self.assertEqual(cose.verify_sign1(untagged, self.public), self.payload)

    def test_rejects_another_key(self):
        other = ec.generate_private_key(ec.SECP384R1()).public_key()
        with self.assertRaises(cose.CoseError):
            cose.verify_sign1(self.signed, other)

    def test_rejects_a_tampered_payload(self):
        tampered = bytearray(self.signed)
        offset = self.signed.index(self.payload)
        tampered[offset] ^= 0x01
        with self.assertRaises(cose.CoseError):
            cose.verify_sign1(bytes(tampered), self.public)

    def test_rejects_a_key_on_another_curve(self):
        p256 = ec.generate_private_key(ec.SECP256R1()).public_key()
        with self.assertRaises(cose.CoseError) as raised:
            cose.verify_sign1(self.signed, p256)
        self.assertIn("secp384r1", str(raised.exception))

    def test_rejects_an_algorithm_that_is_not_a_signature_algorithm(self):
        signed = _sign1(self.key, self.payload, protected=PROTECTED_UNKNOWN_ALG)
        with self.assertRaises(cose.CoseError) as raised:
            cose.verify_sign1(signed, self.public)
        self.assertIn("unsupported COSE algorithm", str(raised.exception))

    def test_rejects_the_wrong_cbor_tag(self):
        wrong_tag = b"\xd8\x3d" + self.signed[1:]
        with self.assertRaises(cose.CoseError) as raised:
            cose.verify_sign1(wrong_tag, self.public)
        self.assertIn("COSE_Sign1", str(raised.exception))

    def test_rejects_a_signature_of_the_wrong_length(self):
        # Well-formed CBOR, but the raw (r || s) signature is one byte short.
        envelope = (
            b"\xd2\x84"
            + cbor.dumps(PROTECTED_ES384)
            + b"\xa0"
            + cbor.dumps(self.payload)
            + cbor.dumps(bytes(95))
        )
        with self.assertRaises(cose.CoseError) as raised:
            cose.verify_sign1(envelope, self.public)
        self.assertIn("expected 96", str(raised.exception))

    def test_es256_is_supported(self):
        key = ec.generate_private_key(ec.SECP256R1())
        signed = _sign1(key, self.payload, protected=PROTECTED_ES256, hash_cls=hashes.SHA256)
        self.assertEqual(cose.verify_sign1(signed, key.public_key()), self.payload)


if __name__ == "__main__":
    unittest.main()
