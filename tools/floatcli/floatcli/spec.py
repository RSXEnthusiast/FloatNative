"""Load the Floatplane OpenAPI spec and validate live responses against it.

The spec lives at `packages/openapi/floatplane-openapi-specification.json`
relative to the repo root. We resolve `$ref` pointers and run the response
JSON through `jsonschema` so we get a precise, ordered list of every place
the live response disagrees with what the iOS/Android decoders expect.

This is the heart of the `decode` and `diff` commands.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from jsonschema import Draft7Validator, RefResolver


def _repo_root() -> Path:
    # tools/floatcli/floatcli/spec.py → repo root is three parents up.
    return Path(__file__).resolve().parents[3]


def default_spec_path() -> Path:
    return _repo_root() / "packages" / "openapi" / "floatplane-openapi-specification.json"


def default_overlay_path() -> Path:
    return _repo_root() / "packages" / "openapi" / "spec-overlay.json"


@lru_cache(maxsize=2)
def load_spec(path: str | None = None) -> dict[str, Any]:
    target = Path(path) if path else default_spec_path()
    with target.open("r", encoding="utf-8") as f:
        spec = json.load(f)
    overlay_path = default_overlay_path()
    if overlay_path.exists():
        with overlay_path.open("r", encoding="utf-8") as f:
            overlay = json.load(f)
        spec = _merge_overlay(spec, overlay)
    return _openapi_to_jsonschema(spec)


def _merge_overlay(base: Any, patch: Any) -> Any:
    """RFC 7396 JSON Merge Patch with `_*` keys treated as comments.

    Same behavior as packages/openapi/scripts/apply-overlay.py — kept here so
    floatcli validates against the same effective spec the iOS/Android codegen
    uses.
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
        out[key] = _merge_overlay(base.get(key), value)
    return out


def _openapi_to_jsonschema(spec: dict[str, Any]) -> dict[str, Any]:
    """Translate OpenAPI 3.0 'nullable: true' into JSON Schema Draft-7.

    Without this, Draft7Validator flags every legitimate `null` as a type
    mismatch and every `oneOf [Ref|string]` whose match contains a nullable
    sub-property as "is not valid under any of the given schemas". Both are
    spurious — the iOS/Android codegen handles `nullable: true` natively.

    Walks the spec mutably and rewrites:
      - {"type": "X", "nullable": true}      → {"type": ["X", "null"]}
      - {"$ref": ..., "nullable": true}      → {"oneOf": [{"$ref": ...}, {"type": "null"}]}
      - {"allOf": [...], "nullable": true}   → wrap in oneOf with null
      - {"oneOf": [...], "nullable": true}   → append {"type": "null"} to the union
    """

    def transform(node: Any) -> Any:
        if isinstance(node, list):
            return [transform(item) for item in node]
        if not isinstance(node, dict):
            return node

        # Recurse first so nested schemas get fixed before parent rewrites.
        rewritten: dict[str, Any] = {k: transform(v) for k, v in node.items()}

        if rewritten.pop("nullable", False) is True:
            if "type" in rewritten and isinstance(rewritten["type"], str):
                rewritten["type"] = [rewritten["type"], "null"]
            elif "oneOf" in rewritten and isinstance(rewritten["oneOf"], list):
                rewritten["oneOf"] = list(rewritten["oneOf"]) + [{"type": "null"}]
            elif "anyOf" in rewritten and isinstance(rewritten["anyOf"], list):
                rewritten["anyOf"] = list(rewritten["anyOf"]) + [{"type": "null"}]
            else:
                # `$ref + nullable`, `allOf + nullable`, or a bare nullable: lift
                # whatever payload is here into a oneOf with explicit null.
                inner = {k: v for k, v in rewritten.items() if k != "description"}
                description = rewritten.get("description")
                rewritten = {"oneOf": [inner, {"type": "null"}]}
                if description:
                    rewritten["description"] = description

        return rewritten

    return transform(spec)


def _path_template_to_regex(template: str) -> re.Pattern[str]:
    # Convert "/api/v3/content/post/{id}" → r"^/api/v3/content/post/[^/]+$"
    pattern = re.sub(r"\{[^/}]+\}", r"[^/]+", template)
    return re.compile(f"^{pattern}$")


def find_operation(
    spec: dict[str, Any], method: str, path: str
) -> tuple[str, dict[str, Any]] | None:
    """Find the operation in the spec for the given (method, request path).

    Returns (matched_template, operation_object) or None. `path` may include
    a query string — we strip it.
    """
    method = method.lower()
    bare_path = urlsplit(path).path
    paths = spec.get("paths", {})

    # Prefer exact matches first, then fall back to templated paths.
    if bare_path in paths and method in paths[bare_path]:
        return bare_path, paths[bare_path][method]

    for template, ops in paths.items():
        if method not in ops:
            continue
        if "{" in template and _path_template_to_regex(template).match(bare_path):
            return template, ops[method]
    return None


def response_schema(operation: dict[str, Any], status: int = 200) -> dict[str, Any] | None:
    responses = operation.get("responses", {})
    candidate = responses.get(str(status)) or responses.get("default")
    if not candidate:
        return None
    content = candidate.get("content", {})
    json_resp = content.get("application/json")
    if not json_resp:
        return None
    return json_resp.get("schema")


@dataclass
class ValidationFinding:
    path: str  # JSON pointer path like "blogPosts.7.metadata"
    message: str
    expected: str | None = None
    actual: str | None = None
    schema_path: str | None = None

    def render(self) -> str:
        path = self.path or "(root)"
        return f"  • {path}: {self.message}"


@dataclass
class ValidationResult:
    operation_id: str | None
    matched_path: str | None
    findings: list[ValidationFinding] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.findings


def _fmt_path(parts: list[Any]) -> str:
    return ".".join(str(p) for p in parts)


def validate_response(
    spec: dict[str, Any],
    *,
    method: str,
    path: str,
    status: int,
    body: Any,
) -> ValidationResult:
    """Validate `body` (already-parsed JSON) against the spec's response schema."""

    op_match = find_operation(spec, method, path)
    if op_match is None:
        return ValidationResult(
            operation_id=None,
            matched_path=None,
            findings=[
                ValidationFinding(
                    path="",
                    message=f"No operation found in spec for {method.upper()} {urlsplit(path).path}",
                )
            ],
        )
    matched_path, operation = op_match
    schema = response_schema(operation, status)
    op_id = operation.get("operationId")
    if not schema:
        return ValidationResult(
            operation_id=op_id,
            matched_path=matched_path,
            findings=[
                ValidationFinding(
                    path="",
                    message=f"Spec has no application/json schema for {status} response",
                )
            ],
        )

    resolver = RefResolver.from_schema(spec)
    validator = Draft7Validator(schema, resolver=resolver)
    findings: list[ValidationFinding] = []
    for err in sorted(validator.iter_errors(body), key=lambda e: list(e.absolute_path)):
        findings.append(
            ValidationFinding(
                path=_fmt_path(list(err.absolute_path)),
                message=err.message,
                schema_path=_fmt_path(list(err.absolute_schema_path)),
            )
        )

    return ValidationResult(
        operation_id=op_id, matched_path=matched_path, findings=findings
    )


def required_keys(schema: dict[str, Any], spec: dict[str, Any]) -> set[str]:
    """Resolve `$ref` and return the `required` keys at the top level of a schema."""
    if "$ref" in schema:
        ref = schema["$ref"]
        if ref.startswith("#/"):
            node: Any = spec
            for part in ref[2:].split("/"):
                node = node[part]
            return required_keys(node, spec)
    return set(schema.get("required", []))
