"""Round-trip a DPoP proof through standard JWT verification.

If this passes we know the proof we generate is byte-for-byte spec-compliant
(matching what `auth.floatplane.com` will expect).
"""

from __future__ import annotations

import base64
import hashlib
import json
import tempfile
from pathlib import Path

import pytest

cryptography = pytest.importorskip("cryptography")

from cryptography.hazmat.primitives import hashes  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature  # noqa: E402

from floatcli.dpop import DPoPKey, generate_proof  # noqa: E402


def _b64url_decode(s: str) -> bytes:
    s = s + "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s)


def test_proof_signs_and_verifies(tmp_path: Path) -> None:
    key = DPoPKey.load_or_create(tmp_path / "k.pem")
    proof = generate_proof(
        key,
        http_method="POST",
        http_url="https://auth.floatplane.com/realms/floatplane/protocol/openid-connect/token?ignored=1",
    )
    header_b64, payload_b64, sig_b64 = proof.split(".")
    header = json.loads(_b64url_decode(header_b64))
    payload = json.loads(_b64url_decode(payload_b64))
    sig = _b64url_decode(sig_b64)
    assert header["typ"] == "dpop+jwt"
    assert header["alg"] == "ES256"
    assert header["jwk"]["crv"] == "P-256"
    assert payload["htm"] == "POST"
    assert payload["htu"].endswith("/openid-connect/token")
    assert "?" not in payload["htu"]  # query stripped per spec
    assert "iat" in payload and "jti" in payload

    # Verify signature: convert raw r||s to DER and ask cryptography to check.
    r = int.from_bytes(sig[:32], "big")
    s = int.from_bytes(sig[32:], "big")
    der = encode_dss_signature(r, s)
    public = key.private_key.public_key()
    public.verify(der, f"{header_b64}.{payload_b64}".encode("ascii"), ec.ECDSA(hashes.SHA256()))


def test_ath_is_sha256_of_token(tmp_path: Path) -> None:
    key = DPoPKey.load_or_create(tmp_path / "k.pem")
    token = "the-quick-brown-fox"
    proof = generate_proof(
        key,
        http_method="GET",
        http_url="https://www.floatplane.com/api/v3/user/self",
        access_token=token,
    )
    _, payload_b64, _ = proof.split(".")
    payload = json.loads(_b64url_decode(payload_b64))
    expected = base64.urlsafe_b64encode(
        hashlib.sha256(token.encode("ascii")).digest()
    ).rstrip(b"=").decode()
    assert payload["ath"] == expected


def test_key_persists(tmp_path: Path) -> None:
    p = tmp_path / "k.pem"
    k1 = DPoPKey.load_or_create(p)
    k2 = DPoPKey.load_or_create(p)
    # Public coordinates should match across loads.
    assert k1.public_jwk() == k2.public_jwk()
