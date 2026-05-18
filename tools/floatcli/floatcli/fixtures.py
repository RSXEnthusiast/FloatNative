"""Capture API responses to disk for regression tests on iOS/Android."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any


def _safe_filename(method: str, path: str) -> str:
    safe = re.sub(r"[^a-zA-Z0-9._-]+", "_", path).strip("_")
    return f"{method.lower()}_{safe}.json"


@dataclass
class FixtureResult:
    path: Path
    bytes_written: int


def save_fixture(
    *,
    out_dir: Path,
    method: str,
    path: str,
    status: int,
    body: Any,
) -> FixtureResult:
    out_dir.mkdir(parents=True, exist_ok=True)
    target = out_dir / _safe_filename(method, path)
    payload = {
        "request": {"method": method.upper(), "path": path},
        "response": {"status": status, "body": body},
    }
    serialized = json.dumps(payload, indent=2, ensure_ascii=False)
    target.write_text(serialized)
    return FixtureResult(path=target, bytes_written=len(serialized.encode("utf-8")))
