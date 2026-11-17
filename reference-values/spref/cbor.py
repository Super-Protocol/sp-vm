"""The small subset of CBOR (RFC 8949) needed to verify a signed CoRIM.

A signed CoRIM is a COSE_Sign1 (RFC 9052) envelope, so verification needs to
decode an array of four items and to encode the Sig_structure that is signed.
Keeping that here means `spref verify` runs on a stock Python with only
`cryptography`, and a customer does not have to install a CBOR library - or
trust this tool - to check the signature.
"""


class CborError(Exception):
    pass


class Tag:
    __slots__ = ("number", "value")

    def __init__(self, number, value):
        self.number = number
        self.value = value

    def __repr__(self):
        return f"Tag({self.number}, {self.value!r})"


def loads(data):
    value, offset = _decode(data, 0)
    if offset != len(data):
        raise CborError(f"{len(data) - offset} trailing byte(s) after the CBOR item")
    return value


def _head(data, offset):
    if offset >= len(data):
        raise CborError("truncated CBOR item")
    initial = data[offset]
    major, additional = initial >> 5, initial & 0x1F
    offset += 1
    if additional < 24:
        return major, additional, offset
    if additional in (24, 25, 26, 27):
        width = 1 << (additional - 24)
        if offset + width > len(data):
            raise CborError("truncated CBOR argument")
        return major, int.from_bytes(data[offset : offset + width], "big"), offset + width
    if additional == 31:
        return major, None, offset
    raise CborError(f"reserved additional information {additional}")


def _decode(data, offset):
    major, argument, offset = _head(data, offset)

    if major == 0:
        return argument, offset
    if major == 1:
        return -1 - argument, offset
    if major in (2, 3):
        if argument is None:
            raise CborError("indefinite-length strings are not supported")
        end = offset + argument
        if end > len(data):
            raise CborError("truncated CBOR string")
        chunk = data[offset:end]
        return (chunk if major == 2 else chunk.decode("utf-8")), end
    if major == 4:
        if argument is None:
            raise CborError("indefinite-length arrays are not supported")
        items = []
        for _ in range(argument):
            item, offset = _decode(data, offset)
            items.append(item)
        return items, offset
    if major == 5:
        if argument is None:
            raise CborError("indefinite-length maps are not supported")
        pairs = {}
        for _ in range(argument):
            key, offset = _decode(data, offset)
            value, offset = _decode(data, offset)
            if isinstance(key, (bytes, str, int)):
                pairs[key] = value
        return pairs, offset
    if major == 6:
        value, offset = _decode(data, offset)
        return Tag(argument, value), offset
    if major == 7:
        if argument == 20:
            return False, offset
        if argument == 21:
            return True, offset
        if argument == 22:
            return None, offset
        raise CborError(f"unsupported simple value {argument}")

    raise CborError(f"unsupported major type {major}")


def _encode_head(major, argument):
    if argument < 24:
        return bytes([(major << 5) | argument])
    for additional, width in ((24, 1), (25, 2), (26, 4), (27, 8)):
        if argument < 1 << (8 * width):
            return bytes([(major << 5) | additional]) + argument.to_bytes(width, "big")
    raise CborError(f"argument {argument} is too large to encode")


def dumps(value):
    """Encode the item kinds a Sig_structure is made of."""
    if isinstance(value, bool) or value is None:
        raise CborError("booleans and null are not needed by this encoder")
    if isinstance(value, int):
        if value < 0:
            return _encode_head(1, -1 - value)
        return _encode_head(0, value)
    if isinstance(value, bytes):
        return _encode_head(2, len(value)) + value
    if isinstance(value, str):
        encoded = value.encode("utf-8")
        return _encode_head(3, len(encoded)) + encoded
    if isinstance(value, (list, tuple)):
        return _encode_head(4, len(value)) + b"".join(dumps(item) for item in value)
    raise CborError(f"cannot encode {type(value).__name__}")
