"""Conversion between PEM EC keys and the JWK form cocli signs with.

The Reference-Values key itself is generated with standard tooling (openssl,
or an HSM that exports only the public half), never by this tool; see
../keys/README.md. All this module does is re-encode a key as a JWK.
"""

import base64
import json

from cryptography.hazmat.primitives.serialization import load_pem_private_key, load_pem_public_key

CURVES = {"secp256r1": ("P-256", "ES256"), "secp384r1": ("P-384", "ES384"), "secp521r1": ("P-521", "ES512")}


class KeyConversionError(Exception):
    pass


def _b64url(value, size):
    return base64.urlsafe_b64encode(value.to_bytes(size, "big")).rstrip(b"=").decode("ascii")


def pem_to_jwk(pem, public_only=False, kid=None):
    """Re-encode a PEM EC key (private or public) as a JWK."""
    private = None
    try:
        private = load_pem_private_key(pem, password=None)
        public = private.public_key()
    except ValueError:
        try:
            public = load_pem_public_key(pem)
        except ValueError as exc:
            raise KeyConversionError(f"not a PEM EC key: {exc}") from exc

    curve = public.curve.name
    if curve not in CURVES:
        raise KeyConversionError(f"unsupported curve {curve}; expected one of {', '.join(CURVES)}")
    crv, alg = CURVES[curve]

    size = (public.curve.key_size + 7) // 8
    numbers = public.public_numbers()
    jwk = {
        "kty": "EC",
        "crv": crv,
        "alg": alg,
        "x": _b64url(numbers.x, size),
        "y": _b64url(numbers.y, size),
    }
    if kid:
        jwk["kid"] = kid
    if private is not None and not public_only:
        jwk["d"] = _b64url(private.private_numbers().private_value, size)
    return json.dumps(jwk, indent=2, sort_keys=True) + "\n"
