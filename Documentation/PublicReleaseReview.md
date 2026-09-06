# Public release review — 2026-09-07

Scope: the files included in the initial public SDK commit, the package manifest,
native networking/session/storage code, example app, tests, documentation and CI.
The private Barky backend and production infrastructure are outside this review.

## Findings and changes

- No real credentials, signing keys, production endpoints, customer messages,
  personal filesystem paths or unrelated organization data were found in the
  public file set. Token-shaped test values are synthetic fixtures.
- Gitleaks 8.30.1 scanned the exported publication snapshot with redaction enabled
  and reported no leaks. The included screenshot was also visually reviewed.
- Local build output, workspace state, signing material, environment files and
  logs are excluded from Git. The backend-dependent integration server is kept
  local and excluded; the public SDK and normal tests do not need that server.
- CI has read-only repository permission, a commit-pinned checkout action,
  disabled credential persistence and a bounded execution time.
- Public commits use the maintainer's GitHub noreply address.
- The owner selected MIT for this repository. No Crisp source, binary or assets
  are included, and the runtime package has no external package dependencies.

## Security behavior reviewed

HTTPS is required except for loopback development. SDK-owned URLSession instances
reject redirects and disable response caching/cookies. Channel server keys are not
accepted as customer credentials. Refreshed customer identity changes invalidate
the client; logout clears visible state and cancels work. Pending sends use durable,
customer-scoped Keychain records and stable idempotency keys.

The host application's authenticated backend remains responsible for authorization,
customer isolation, session issuance, abuse limits, and server-side retention.
Logout intentionally keeps the local conversation record; the API for deleting it
is documented. Custom network protocols are trusted host-app configuration.

## Validation before publication

- Core tests: 16 passed, 0 failed; 1 optional backend integration test skipped.
- The iOS example compiled successfully from a clean export containing only the
  public files, without signing or access to private backend code.
- Privacy manifest validation and staged whitespace checks passed.

This is a bounded source/publication review, not a penetration test or a guarantee
that the SDK or its integrating applications contain no vulnerabilities.
