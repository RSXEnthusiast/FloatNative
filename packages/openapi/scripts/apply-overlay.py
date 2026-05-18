#!/usr/bin/env python3
"""Apply spec-overlay.json to floatplane-openapi-specification.json.

Implements RFC 7396 (JSON Merge Patch) but ignores keys whose name starts with
"_" so we can document each override inline. Outputs a merged spec to stdout
or to a file passed on argv[1]. Both generate-swift.sh and generate-kotlin.sh
call this before invoking openapi-generator so the loosenings + extensions
flow into the generated models on both platforms.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


HERE = Path(__file__).resolve().parent
PACKAGE_DIR = HERE.parent
SPEC_PATH = PACKAGE_DIR / "floatplane-openapi-specification.json"
OVERLAY_PATH = PACKAGE_DIR / "spec-overlay.json"


def merge(base: Any, patch: Any) -> Any:
    """RFC 7396 merge with one twist: keys starting with `_` in `patch` are
    treated as comments and dropped. `null` in the patch deletes the key,
    same as the spec.
    """
    if not isinstance(patch, dict):
        return patch
    if not isinstance(base, dict):
        base = {}
    out = dict(base)
    for key, value in patch.items():
        if key.startswith("_"):
            continue
        if value is None:
            out.pop(key, None)
            continue
        out[key] = merge(base.get(key), value)
    return out


def main() -> int:
    if not SPEC_PATH.exists():
        print(f"❌ Spec not found at {SPEC_PATH}", file=sys.stderr)
        return 1
    with SPEC_PATH.open("r", encoding="utf-8") as f:
        spec = json.load(f)

    if OVERLAY_PATH.exists():
        with OVERLAY_PATH.open("r", encoding="utf-8") as f:
            overlay = json.load(f)
        merged = merge(spec, overlay)
    else:
        merged = spec

    output = json.dumps(merged, indent=2, ensure_ascii=False)
    if len(sys.argv) > 1:
        Path(sys.argv[1]).write_text(output, encoding="utf-8")
    else:
        sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
