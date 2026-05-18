"""Verifies the OpenAPI 3.0 → JSON Schema Draft-7 transform handles the
`nullable: true` quirk correctly. Without this, every legitimate null in a
real Floatplane response gets flagged as schema drift.
"""

from __future__ import annotations

import pytest

jsonschema = pytest.importorskip("jsonschema")

from floatcli.spec import _openapi_to_jsonschema, validate_response  # noqa: E402


def test_nullable_string_accepts_null() -> None:
    spec = {
        "paths": {
            "/x": {
                "get": {
                    "responses": {
                        "200": {
                            "content": {
                                "application/json": {
                                    "schema": {"$ref": "#/components/schemas/Plan"}
                                }
                            }
                        }
                    }
                }
            }
        },
        "components": {
            "schemas": {
                "Plan": {
                    "type": "object",
                    "properties": {
                        "logo": {"type": "string", "nullable": True},
                    },
                    "required": ["logo"],
                }
            }
        },
    }
    fixed = _openapi_to_jsonschema(spec)
    result = validate_response(
        fixed, method="GET", path="/x", status=200, body={"logo": None}
    )
    assert result.ok, [f.message for f in result.findings]


def test_nullable_ref_accepts_null() -> None:
    spec = {
        "paths": {
            "/x": {
                "get": {
                    "responses": {
                        "200": {
                            "content": {
                                "application/json": {
                                    "schema": {"$ref": "#/components/schemas/Channel"}
                                }
                            }
                        }
                    }
                }
            }
        },
        "components": {
            "schemas": {
                "Channel": {
                    "type": "object",
                    "properties": {
                        "cover": {
                            "allOf": [{"$ref": "#/components/schemas/Image"}],
                            "nullable": True,
                        }
                    },
                    "required": ["cover"],
                },
                "Image": {
                    "type": "object",
                    "properties": {"path": {"type": "string"}},
                    "required": ["path"],
                },
            }
        },
    }
    fixed = _openapi_to_jsonschema(spec)
    result = validate_response(
        fixed, method="GET", path="/x", status=200, body={"cover": None}
    )
    assert result.ok, [f.message for f in result.findings]


def test_real_drift_still_caught() -> None:
    """Sanity: an actually-missing required field must still surface."""
    spec = {
        "paths": {
            "/x": {
                "get": {
                    "responses": {
                        "200": {
                            "content": {
                                "application/json": {
                                    "schema": {"$ref": "#/components/schemas/Plan"}
                                }
                            }
                        }
                    }
                }
            }
        },
        "components": {
            "schemas": {
                "Plan": {
                    "type": "object",
                    "properties": {"interval": {"type": "string"}},
                    "required": ["interval"],
                }
            }
        },
    }
    fixed = _openapi_to_jsonschema(spec)
    result = validate_response(
        fixed, method="GET", path="/x", status=200, body={}
    )
    assert not result.ok
    assert any("interval" in f.message for f in result.findings)
