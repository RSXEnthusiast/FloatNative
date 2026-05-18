# API Response Fixtures

Anonymized JSON snapshots of real Floatplane API responses, used by
`FixtureDecodeTests.swift` to detect schema drift before it hits TestFlight.

## Format

Each fixture is the response from `floatcli`'s `--capture` flag:

```json
{
  "request": { "method": "GET", "path": "/api/v3/..." },
  "response": { "status": 200, "body": { ... } }
}
```

`FixtureDecodeTests` finds every `*.json` in this folder, looks at the
`request.path`, and decodes the body through the production model that the
iOS app uses for that path (e.g. `CreatorListResponse` for
`/api/v3/content/creator/list`). Anything that fails fails the test.

## Capturing new fixtures

From the repo root:

```bash
floatcli decode '/api/v3/content/creator/list?ids[0]=...&limit=20' \
  --capture apps/ios/FloatNativeTests/Fixtures/
```

Before committing, scrub anything user-identifying: tokens, sails.sid cookies,
email addresses, profile-image hashes that link back to your account, etc. The
fixture should represent shape, not personal data.

## Adding support for a new endpoint

Edit the route table in `FixtureDecodeTests.swift` so it knows which Decodable
to use for the new path.
