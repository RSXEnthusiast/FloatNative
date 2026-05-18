"""HTTP client for the FloatNative Companion API."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import httpx

from .floatplane import USER_AGENT
from .storage import Credentials

COMPANION_BASE = "https://api.floatnative.coulterpeterson.com"


@dataclass
class CompanionResponse:
    status_code: int
    headers: dict[str, str]
    body: bytes

    @property
    def text(self) -> str:
        return self.body.decode("utf-8", errors="replace")

    def json(self) -> Any:
        import json

        return json.loads(self.text)


class CompanionClient:
    """Wraps api.floatnative.coulterpeterson.com.

    Authenticates with the API key returned by `POST /auth/login` (Floatplane
    OAuth + DPoP exchange). For now we treat the api_key as supplied through
    Credentials; obtaining one requires the DPoP proof flow that the iOS app
    uses on first launch.
    """

    def __init__(
        self,
        *,
        credentials: Credentials,
        client: httpx.Client | None = None,
    ) -> None:
        self.credentials = credentials
        self._client = client or httpx.Client(
            timeout=30,
            headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
        )

    def close(self) -> None:
        self._client.close()

    def __enter__(self) -> "CompanionClient":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def request(
        self,
        method: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
        json_body: Any = None,
        authenticated: bool = True,
    ) -> CompanionResponse:
        headers: dict[str, str] = {}
        if authenticated:
            if not self.credentials.companion_api_key:
                raise RuntimeError(
                    "No companion API key. Run `floatcli companion login` first."
                )
            headers["Authorization"] = f"Bearer {self.credentials.companion_api_key}"

        resp = self._client.request(
            method,
            f"{COMPANION_BASE}{path}",
            params=params,
            json=json_body,
            headers=headers,
        )
        return CompanionResponse(
            status_code=resp.status_code,
            headers=dict(resp.headers),
            body=resp.content,
        )
