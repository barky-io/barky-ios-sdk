# Public release review — 2026-09-07

## Read receipts — 2026-09-10

Version 0.3.0 reports displayed support-message IDs through the existing private
customer session. No new credentials, permissions, runtime dependencies, or
message bodies are introduced in receipt requests. Read receipts are cancelled
when the screen is hidden or the app becomes inactive, and receipt failures retry
without blocking chat. The privacy manifest declares product interaction for app
functionality, linked to the customer and not used for tracking.

Core verification passed 25 tests; two optional fixture-backed tests were skipped.
Five new tests cover viewport bounds, foreground visibility, duplicate suppression,
identity reset, and failed receipt retries. All three Simulator UI tests passed.
An actual host app and the development Inbox verified a saved reply becoming read
after it was displayed. This is local development evidence, not a hosted API deployment.
The host-app check also kept background and offscreen replies at `Sent`, while a
visible reply became `Read`. The staged public snapshot passed redacted Gitleaks
with no findings. No host-app keys, private paths, or customer content are included.

## Hosted endpoint default — 2026-09-10

Version 0.2.1 makes the API URL optional. The public Barky service address is
included in the SDK; apps only supply their SDK API key. The published service
address is not a credential. No live API keys or customer data are included.
Explicit endpoint overrides remain available for development and testing.

The demo uses the same API-key-only initializer and intercepts every SDK request
with its synthetic transport, so it does not send demo messages to Barky.
Local verification passed 20 package tests; two optional backend integration tests
were skipped because their disposable server was not running. The new transport
test checks the default HTTPS host and API paths for session creation and sending.

## SDK API key update — 2026-09-09

Version 0.2.0 adds direct Barky integration using a publishable `bk_sdk_…` API key.
The SDK creates and saves a random private installation credential before calling
`POST /sdk/sessions`. The key cannot substitute for a customer session or a channel
server key. The installation credential is now persisted in device-only Keychain;
privacy and logout/reset documentation has been updated accordingly.

The 33-file public snapshot passed Gitleaks with no findings. It contains no private
backend source or live credentials. The privacy manifest passed validation. All 21
package tests (including direct HTTP integration) and three Simulator UI tests passed.
The original review below describes the initial 0.1.0 server-provider integration.

## Initial publication scope

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

## 0.4.0 scope

Adds opt-in APNs registration, authenticated notification routing, awaited cleanup,
and English integration documentation. APNs provider keys remain in the Barky service;
the package accepts only a device token from the host app. No private keys, real device
tokens, application credentials, customer conversations, or internal server code are
included. The SDK does not swizzle delegates or request notification permission.
Device ID is declared in the privacy manifest for optional push functionality.

Validation for 0.4.0: 31 package tests passed; two optional live fixture tests were
skipped. Three iOS Simulator UI tests passed. The public file export passed redacted
Gitleaks with no findings, and the privacy manifest/whitespace checks passed.
These checks do not establish live APNs acceptance or device delivery.

## 0.4.1 scope

Starts a newly presented chat at the latest message when notification routing has
already loaded the conversation. No network, storage, permission, or payload
changes. The regression fixture contains only synthetic messages generated by the
demo transport and is available only with the UI testing launch argument.

The new regression test failed before the fix and passed for both UIKit and SwiftUI
presentations after it. All four iOS Simulator UI tests and 31 package tests passed;
two optional live fixture tests were skipped. The public file export passed
redacted Gitleaks with no findings.

## 0.4.2 scope

Completes the initial scroll after lazy rows recalculate their heights, including
replies that span multiple screens. The adjustment ends when the latest reply is
visible so readers can scroll back normally. Directly presented UIKit chat screens
also report their window scene's active state so visible replies are acknowledged
and polling stops when the screen is inactive. No API or privacy changes.

The expanded synthetic regression failed on 0.4.1 and passed after the fix in both
UIKit and SwiftUI. The direct UIKit fixture also checks the latest reply's read
receipt, and both presentations check that scrolling back is preserved.

All four iOS Simulator UI tests passed. A local host app also received a real
APNs Sandbox alert, opened the latest reply, and sent a successful read receipt.
This does not establish Production APNs or physical-device behavior. The public
export passed redacted Gitleaks with no findings.

## 0.5.0 scope

Adds system properties, custom user/device JSON properties, collection controls,
and a locally generated Barky visitor UUID. The SDK restores an existing Keychain
UUID or creates one locally before networking. Public IDs remain separate from the
private installation credential and internal server customer ID. Reset rotates the
local identity; existing installations retain their private credential and history.

Default metadata includes device family/model code, OS/app versions, language,
locale and timezone. IP location is requested from the service's trusted ingress;
no GPS, IDFA, IDFV, user-assigned device name, raw IP, or coordinates are collected
into profiles. The privacy manifest adds coarse location and other data for app
functionality, linked to the customer and not used for tracking. English docs
explain defaults, opt-outs, retention boundaries, limits and custom-property trust.

Verification: 40 package tests passed with the disposable HTTP/PostgreSQL fixture,
including local/offline identity, restoration/reset, custom-property round trips,
and compatibility with older bootstrap endpoints. Four iOS Simulator UI tests
passed. The private server suite passed 29 tests, including tenant isolation,
local-ID binding conflicts, atomic patches and merged payload limits; web tests,
type checking, lint and build also passed. These are local verification results,
not a hosted API deployment or a physical-device check.

The implementation is original. Amplitude's public documentation and ID lifecycle
were consulted; no Amplitude code, binary, dependency, or assets are included.
