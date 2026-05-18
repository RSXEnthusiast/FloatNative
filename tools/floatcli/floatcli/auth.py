"""OAuth device-code flow against auth.floatplane.com.

Mirrors what FloatplaneAPI.swift does for the iOS device login flow:
1. POST /realms/floatplane/protocol/openid-connect/auth/device → user_code + verification_uri_complete
2. User opens that URI in a browser and approves
3. POLL /realms/floatplane/protocol/openid-connect/token (grant_type=urn:ietf:params:oauth:grant-type:device_code)
   with a DPoP proof until we get back access + refresh tokens
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any

import httpx

from .dpop import DPoPKey, generate_proof
from .storage import Credentials

AUTH_BASE = "https://auth.floatplane.com"
REALM = "floatplane"
CLIENT_ID = "floatnative"

DEVICE_AUTH_URL = f"{AUTH_BASE}/realms/{REALM}/protocol/openid-connect/auth/device"
TOKEN_URL = f"{AUTH_BASE}/realms/{REALM}/protocol/openid-connect/token"


class AuthError(RuntimeError):
    """Authentication-related failure."""


@dataclass(frozen=True)
class DeviceCodeResponse:
    device_code: str
    user_code: str
    verification_uri: str
    verification_uri_complete: str
    expires_in: int
    interval: int


def start_device_auth(*, client: httpx.Client | None = None) -> DeviceCodeResponse:
    own_client = client is None
    client = client or httpx.Client(timeout=30)
    try:
        resp = client.post(
            DEVICE_AUTH_URL,
            data={"client_id": CLIENT_ID, "scope": "openid profile email"},
            headers={"User-Agent": "floatcli/0.1.0"},
        )
        resp.raise_for_status()
        body = resp.json()
        return DeviceCodeResponse(
            device_code=body["device_code"],
            user_code=body["user_code"],
            verification_uri=body["verification_uri"],
            verification_uri_complete=body.get(
                "verification_uri_complete", body["verification_uri"]
            ),
            expires_in=int(body["expires_in"]),
            interval=int(body.get("interval", 5)),
        )
    finally:
        if own_client:
            client.close()


def poll_for_token(
    device_code: str,
    *,
    key: DPoPKey,
    interval: int = 5,
    max_seconds: int = 600,
    client: httpx.Client | None = None,
) -> Credentials:
    own_client = client is None
    client = client or httpx.Client(timeout=30)
    deadline = time.time() + max_seconds
    nonce: str | None = None

    try:
        while time.time() < deadline:
            time.sleep(interval)
            proof = generate_proof(
                key, http_method="POST", http_url=TOKEN_URL, nonce=nonce
            )
            resp = client.post(
                TOKEN_URL,
                data={
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "client_id": CLIENT_ID,
                    "device_code": device_code,
                },
                headers={
                    "DPoP": proof,
                    "User-Agent": "floatcli/0.1.0",
                    "Content-Type": "application/x-www-form-urlencoded",
                },
            )
            new_nonce = resp.headers.get("DPoP-Nonce")
            if new_nonce:
                nonce = new_nonce

            if resp.status_code == 200:
                body = resp.json()
                return Credentials(
                    access_token=body["access_token"],
                    refresh_token=body.get("refresh_token"),
                    expires_at=time.time() + int(body["expires_in"]),
                )

            err: dict[str, Any] = {}
            try:
                err = resp.json()
            except Exception:  # pragma: no cover  noqa: BLE001
                pass

            error = err.get("error")
            if error == "authorization_pending":
                continue
            if error == "slow_down":
                interval += 5
                continue
            if error == "use_dpop_nonce":
                # Server now wants us to retry with the nonce it just sent. Do
                # so immediately rather than waiting another `interval`.
                continue
            raise AuthError(
                f"Token endpoint returned {resp.status_code}: "
                f"{err.get('error_description') or err.get('error') or resp.text}"
            )
        raise AuthError("Device authorization timed out (10 minutes)")
    finally:
        if own_client:
            client.close()


def refresh_credentials(
    creds: Credentials,
    *,
    key: DPoPKey,
    client: httpx.Client | None = None,
) -> Credentials:
    if not creds.refresh_token:
        raise AuthError("No refresh token saved. Run `floatcli auth login` again.")

    own_client = client is None
    client = client or httpx.Client(timeout=30)
    nonce: str | None = None
    try:
        for _ in range(2):
            proof = generate_proof(
                key, http_method="POST", http_url=TOKEN_URL, nonce=nonce
            )
            resp = client.post(
                TOKEN_URL,
                data={
                    "grant_type": "refresh_token",
                    "client_id": CLIENT_ID,
                    "refresh_token": creds.refresh_token,
                },
                headers={
                    "DPoP": proof,
                    "User-Agent": "floatcli/0.1.0",
                    "Content-Type": "application/x-www-form-urlencoded",
                },
            )
            new_nonce = resp.headers.get("DPoP-Nonce")
            if new_nonce:
                nonce = new_nonce
            if resp.status_code == 200:
                body = resp.json()
                return Credentials(
                    access_token=body["access_token"],
                    refresh_token=body.get("refresh_token", creds.refresh_token),
                    expires_at=time.time() + int(body["expires_in"]),
                    companion_api_key=creds.companion_api_key,
                )
            try:
                err = resp.json()
            except Exception:  # noqa: BLE001
                err = {}
            if err.get("error") == "use_dpop_nonce" and nonce:
                continue
            raise AuthError(
                f"Token refresh returned {resp.status_code}: "
                f"{err.get('error_description') or err.get('error') or resp.text}"
            )
        raise AuthError("Token refresh exhausted retries")
    finally:
        if own_client:
            client.close()
