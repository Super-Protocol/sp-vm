import unittest

from spref import cbor


class DecodeTest(unittest.TestCase):
    # Vectors from RFC 8949 appendix A.
    def test_unsigned_integers(self):
        self.assertEqual(cbor.loads(bytes.fromhex("00")), 0)
        self.assertEqual(cbor.loads(bytes.fromhex("17")), 23)
        self.assertEqual(cbor.loads(bytes.fromhex("1818")), 24)
        self.assertEqual(cbor.loads(bytes.fromhex("1903e8")), 1000)
        self.assertEqual(cbor.loads(bytes.fromhex("1a000f4240")), 1000000)
        self.assertEqual(cbor.loads(bytes.fromhex("1b000000e8d4a51000")), 1000000000000)

    def test_negative_integers(self):
        self.assertEqual(cbor.loads(bytes.fromhex("20")), -1)
        self.assertEqual(cbor.loads(bytes.fromhex("3863")), -100)
        self.assertEqual(cbor.loads(bytes.fromhex("3822")), -35)

    def test_strings(self):
        self.assertEqual(cbor.loads(bytes.fromhex("4401020304")), b"\x01\x02\x03\x04")
        self.assertEqual(cbor.loads(bytes.fromhex("6449455446")), "IETF")

    def test_arrays_and_maps(self):
        self.assertEqual(cbor.loads(bytes.fromhex("83010203")), [1, 2, 3])
        self.assertEqual(cbor.loads(bytes.fromhex("a201020304")), {1: 2, 3: 4})
        self.assertEqual(cbor.loads(bytes.fromhex("a0")), {})

    def test_simple_values(self):
        self.assertEqual(cbor.loads(bytes.fromhex("f4")), False)
        self.assertEqual(cbor.loads(bytes.fromhex("f5")), True)
        self.assertIsNone(cbor.loads(bytes.fromhex("f6")))

    def test_tags(self):
        item = cbor.loads(bytes.fromhex("d28101"))
        self.assertIsInstance(item, cbor.Tag)
        self.assertEqual(item.number, 18)
        self.assertEqual(item.value, [1])

    def test_rejects_trailing_bytes(self):
        with self.assertRaises(cbor.CborError):
            cbor.loads(bytes.fromhex("0000"))

    def test_rejects_truncated_input(self):
        with self.assertRaises(cbor.CborError):
            cbor.loads(bytes.fromhex("44010203"))

    def test_rejects_indefinite_length(self):
        with self.assertRaises(cbor.CborError):
            cbor.loads(bytes.fromhex("9f01ff"))


class EncodeTest(unittest.TestCase):
    def test_round_trips_sig_structure_shapes(self):
        value = ["Signature1", b"\xa1\x01\x38\x22", b"", b"payload"]
        self.assertEqual(cbor.loads(cbor.dumps(value)), value)

    def test_integers(self):
        self.assertEqual(cbor.dumps(0), bytes.fromhex("00"))
        self.assertEqual(cbor.dumps(1000), bytes.fromhex("1903e8"))
        self.assertEqual(cbor.dumps(-35), bytes.fromhex("3822"))

    def test_long_byte_string_head(self):
        encoded = cbor.dumps(b"\x00" * 300)
        self.assertEqual(encoded[:3], bytes.fromhex("59012c"))
        self.assertEqual(cbor.loads(encoded), b"\x00" * 300)

    def test_refuses_unsupported_types(self):
        for value in (True, None, 1.5, {"a": 1}):
            with self.assertRaises(cbor.CborError):
                cbor.dumps(value)


if __name__ == "__main__":
    unittest.main()
