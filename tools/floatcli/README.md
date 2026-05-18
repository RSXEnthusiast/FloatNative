# floatcli

Diagnostic CLI for the Floatplane and FloatNative Companion APIs. Mirrors what
the iOS and Android apps do (DPoP, OAuth device-code, identical endpoints) so
you can reproduce auth bugs and decode failures from a terminal — and validate
real responses against the OpenAPI spec to find drift the iOS/Android decoders
will choke on.

## Why this exists

The iOS app shows errors like:

> Failed to load feed: Failed to decode response: The data couldn't be read because it is missing.

That string is Swift's `DecodingError.keyNotFound` localized — it tells you
*something* is missing, but not *what*. This CLI fetches the same endpoint and
runs the response through the OpenAPI schema, printing every required key
that's missing and every type mismatch with a JSON pointer path.

## Install

The CLI requires Python 3.11+. From the repo root:

```bash
# With uv (recommended)
uv tool install --editable tools/floatcli

# Or with pip in a venv
python3 -m venv ~/.venvs/floatcli
~/.venvs/floatcli/bin/pip install --editable tools/floatcli
ln -s ~/.venvs/floatcli/bin/floatcli ~/.local/bin/floatcli
```

Verify:

```bash
floatcli --version
floatcli spec-info
```

## Login

```bash
floatcli auth login
```

Opens a device-code flow against `auth.floatplane.com`. Same realm and
client_id (`floatnative`) the iOS/Android apps use. Tokens land in
`~/Library/Application Support/floatcli/credentials.json` (macOS) /
`~/.config/floatcli/credentials.json` (Linux), mode 0600.

The DPoP keypair persists across runs in `dpop_key.pem` next to the
credentials file.

```bash
floatcli auth status     # shows expiry, redacted token preview
floatcli auth refresh    # forces a refresh token swap
floatcli auth logout     # deletes the local credentials only
```

## Diagnose a decode failure

```bash
# Reproduce the exact request the iOS home feed makes:
floatcli feed home

# Or, hit any endpoint and validate against the spec:
floatcli decode '/api/v3/content/creator/list?ids[0]=59f94c0bdd241b70349eb72b&limit=20'
```

`decode` emits a structured list of every place the live response disagrees
with the spec — fields that should be there but aren't, types that don't
match, enums with new unknown values:

```
operation: getMultiCreatorBlogPosts (/api/v3/content/creator/list)
✗ 1 schema deviation(s):
  • blogPosts.7.metadata.isFeatured: 'isFeatured' is a required property
```

That's the level of detail you want in your bug reports. Run with
`--show-body` to dump the full response, or `--capture <dir>` to save the
response as a fixture.

## Capture fixtures for regression tests

```bash
floatcli decode '/api/v3/content/creator/list?ids[0]=...&limit=20' --capture ../../apps/ios/FloatNativeTests/Fixtures/
```

The iOS test target loads everything in
`apps/ios/FloatNativeTests/Fixtures/` and decodes it through the production
models — so anything captured here becomes a regression test.

## Companion API

```bash
floatcli companion set-key <api_key>      # paste from iOS Keychain or the iOS debug log
floatcli companion get /playlists
floatcli companion get /watch-later
floatcli companion get /ltt/search?q=linus
```

Bootstrapping a companion API key from scratch (i.e. without copying from the
iOS app) requires `POST /auth/login` with a Floatplane access token and DPoP
proof — that flow is on the roadmap but not yet wired into the CLI.

## Layout

```
tools/floatcli/
├── pyproject.toml
├── floatcli/
│   ├── auth.py          # OAuth device-code flow
│   ├── cli.py           # Typer entry point
│   ├── companion.py     # Companion API client
│   ├── dpop.py          # P-256 / ES256 DPoP proof, mirrors DPoPManager.swift
│   ├── fixtures.py      # Capture responses for regression tests
│   ├── floatplane.py    # Authenticated httpx client w/ refresh + nonce loop
│   ├── spec.py          # Load + validate against the OpenAPI spec
│   └── storage.py       # Credential and key persistence
└── tests/
    └── test_dpop.py     # Round-trip a DPoP proof through the JWS spec
```

## What it does NOT do

- Does not mock or proxy traffic. Every command hits real Floatplane.
- Does not store passwords or sails.sid cookies — auth is OAuth + DPoP only.
- Does not trigger any state-changing endpoint by default. `floatcli get`
  only does GETs. (Companion `PATCH`/`PUT`/`DELETE` will require an explicit
  flag once added.)
