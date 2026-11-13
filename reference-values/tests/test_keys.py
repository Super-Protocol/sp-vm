import json
import unittest

from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import Encoding, NoEncryption, PrivateFormat
from cryptography.hazmat.primitives.serialization import PublicFormat

from spref import cose, keys


def _pem(key, private=True):
    if private:
        return key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption())
    return key.public_key().public_bytes(Encoding.PEM, PublicFormat.SubjectPublicKeyInfo)


class PemToJwkTest(unittest.TestCase):
    def setUp(self):
        self.key = ec.generate_private_key(ec.SECP384R1())

    def test_private_key_keeps_the_private_half(self):
        jwk = json.loads(keys.pem_to_jwk(_pem(self.key)))
        self.assertEqual(jwk["crv"], "P-384")
        self.assertEqual(jwk["alg"], "ES384")
        self.assertIn("d", jwk)

    def test_public_only_drops_the_private_half(self):
        jwk = json.loads(keys.pem_to_jwk(_pem(self.key), public_only=True))
        self.assertNotIn("d", jwk)

    def test_a_public_pem_round_trips_to_the_same_point(self):
        jwk = keys.pem_to_jwk(_pem(self.key, private=False))
        loaded = cose.public_key_from_jwk(jwk)
        self.assertEqual(
            loaded.public_numbers(), self.key.public_key().public_numbers()
        )

    def test_records_the_key_id(self):
        jwk = json.loads(keys.pem_to_jwk(_pem(self.key), kid="sp-rv-2026"))
        self.assertEqual(jwk["kid"], "sp-rv-2026")

    def test_p256_is_es256(self):
        key = ec.generate_private_key(ec.SECP256R1())
        self.assertEqual(json.loads(keys.pem_to_jwk(_pem(key)))["alg"], "ES256")

    def test_rejects_a_non_pem_input(self):
        with self.assertRaises(keys.KeyConversionError):
            keys.pem_to_jwk(b"not a key")

    def test_rejects_an_unsupported_curve(self):
        key = ec.generate_private_key(ec.SECP192R1())
        with self.assertRaises(keys.KeyConversionError):
            keys.pem_to_jwk(_pem(key))


if __name__ == "__main__":
    unittest.main()
