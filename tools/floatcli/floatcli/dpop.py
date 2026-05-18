"""DPoP proof generation. Mirrors apps/ios/FloatNative/Services/DPoPManager.swift.

DPoP (RFC 9449) binds an access token to a per-client P-256 keypair. The proof
JWT is sent in the `DPoP` header on every authenticated request. The Floatplane
authorization server is strict about this — without it, /api/v3/* returns 401.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _b64url_uint(value: int, byte_length: int) -> str:
    return _b64url(value.to_bytes(byte_length, "big"))


@dataclass(frozen=True)
class DPoPKey:
    """A persisted P-256 signing key. Mirrors KeychainManager-stored DPoP key on iOS."""

    private_key: ec.EllipticCurvePrivateKey

    @classmethod
    def load_or_create(cls, path: Path) -> "DPoPKey":
        if path.exists():
            pem = path.read_bytes()
            key = serialization.load_pem_private_key(pem, password=None)
            if not isinstance(key, ec.EllipticCurvePrivateKey):
                raise ValueError(f"DPoP key at {path} is not an EC key")
            return cls(private_key=key)
        path.parent.mkdir(parents=True, exist_ok=True)
        key = ec.generate_private_key(ec.SECP256R1())
        pem = key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
        path.write_bytes(pem)
        os.chmod(path, 0o600)
        return cls(private_key=key)

    def public_jwk(self) -> dict[str, str]:
        nums = self.private_key.public_key().public_numbers()
        # P-256 coords are 32 bytes each, big-endian.
        return {
            "kty": "EC",
            "crv": "P-256",
            "x": _b64url_uint(nums.x, 32),
            "y": _b64url_uint(nums.y, 32),
        }

    def sign(self, message: bytes) -> bytes:
        # ES256 signature for JWT is r||s (each 32 bytes), not the DER form
        # that cryptography returns by default.
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

        der = self.private_key.sign(message, ec.ECDSA(hashes.SHA256()))
        r, s = decode_dss_signature(der)
        return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def _strip_query(url: str) -> str:
    parts = urlsplit(url)
    return urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))


def generate_proof(
    key: DPoPKey,
    *,
    http_method: str,
    http_url: str,
    access_token: str | None = None,
    nonce: str | None = None,
) -> str:
    """Generate a DPoP proof JWT for a single request.

    `http_url` must include scheme and host. The query string is stripped from
    `htu` per the spec — Floatplane's auth server rejects proofs with a query
    string in `htu`.
    """
    header = {"typ": "dpop+jwt", "alg": "ES256", "jwk": key.public_jwk()}

    claims: dict[str, object] = {
        "iat": int(time.time()),
        "jti": str(uuid.uuid4()),
        "htm": http_method.upper(),
        "htu": _strip_query(http_url),
    }
    if access_token is not None:
        ath = hashlib.sha256(access_token.encode("ascii")).digest()
        claims["ath"] = _b64url(ath)
    if nonce is not None:
        claims["nonce"] = nonce

    encoded_header = _b64url(
        json.dumps(header, separators=(",", ":"), sort_keys=False).encode("utf-8")
    )
    encoded_claims = _b64url(
        json.dumps(claims, separators=(",", ":"), sort_keys=False).encode("utf-8")
    )
    signing_input = f"{encoded_header}.{encoded_claims}".encode("ascii")
    signature = key.sign(signing_input)
    return f"{encoded_header}.{encoded_claims}.{_b64url(signature)}"
