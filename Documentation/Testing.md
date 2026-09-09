# Verification

## Read receipt verification — 2026-09-10

- 25 core tests passed, including five new read-receipt tests. Two optional
  fixture-backed HTTP tests were skipped because their fixture was not running.
- Tests cover fetched-but-unseen messages, offscreen/prefetched rows, partial
  visibility, backgrounding, duplicate acknowledgements, retries and identity reset.
- Three iOS Simulator UI tests passed for SwiftUI and UIKit presentation.
- A real host app connected to the development API confirmed the Inbox changes
  from `Sent` to `Read` only after the support reply is displayed.
- In that host app, background and offscreen replies stayed `Sent`; a long reply
  visible in the viewport became `Read` independently of the offscreen reply.

## Core tests

```sh
swift test
```

The package's networking/session/state layer can be tested on macOS 13+.
The presentation API is iOS-only. URLProtocol fixtures verify requests and responses;
they do not represent a live server test.

## iOS UI

Open `Examples/BarkyDemo/BarkyDemo.xcodeproj`, select **BarkyDemo** and an iOS Simulator,
then use Product → Test. The UI tests cover sending, receiving a synthetic reply,
closing/reopening the same chat, failed-send retry, and UIKit presentation.

The checked-in Xcode project directly consumes the root SPM product. If it needs
regenerating, run `ruby Examples/BarkyDemo/generate-project.rb` with the `xcodeproj` gem.

## Maintainer backend integration

`LiveIntegrationTests` is optional. It requires a maintainer-provided disposable
loopback fixture with session issuance and synthetic operator replies. That server
depends on private backend code and is not distributed with the public SDK.
Normal `swift test` and CI do not require backend access or credentials.

With that fixture running:

```sh
BARKY_INTEGRATION_URL=http://127.0.0.1:55440 swift test
```

This test uses the production Barky request handler/storage functions against the
isolated database. It verifies an SDK-created conversation, a real operator reply,
internal-note exclusion, session renewal through a new client, conversation restoration,
and a follow-up customer message reopening the conversation.

## Verified on 2026-09-09

- 21 Swift package tests passed, including both real HTTP/PostgreSQL integration tests;
  no tests were skipped in the fixture-backed run.
- The direct SDK API key flow created a conversation, received an operator reply,
  excluded an internal note, restored the visitor after client recreation, and
  started a new visitor after reset. No host session-provider callback was used.
- Three iOS Simulator UI tests passed with the demo's SDK API key configuration:
  send/reply/reopen, failed-send retry, and UIKit presentation.
- Fixtures also cover durable installation credentials, storage failures before
  network requests, lost bootstrap responses, session renewal after HTTP 401, and reset.

These are local verification results, not a production API deployment.

## Verified on 2026-09-06

- 17 package tests passed, including the real HTTP/PostgreSQL integration test;
  no tests were skipped in that run.
- The SPM product built and launched through the example iOS app.
- Three iOS UI tests passed on iPhone 17 Pro / iOS 26.5: send/reply/reopen,
  failed-send retry, and UIKit open/close.
- The privacy manifest passed `plutil -lint`.
- The Korean empty conversation/composer was inspected on Simulator after adding
  the example host's mixed-localization setting; see [capture](Screenshots/chat-ko.jpg).
- The temporary HTTP fixture and PostgreSQL container were stopped after testing.

These results cover local integration and Simulator execution. No production
deployment, physical-device validation, remote package publication, or release tag
was performed.

## Push notifications

`PushNotificationTests` exercises token encoding and private-session registration,
registration cleanup after recreation, failed-cleanup retention, malformed/unrelated
payloads, and authenticated routing without read receipts. No real device token or
APNs key is included in these fixtures. See [device testing](PushNotifications.md#delivery-behavior-and-testing)
for the signed-app checks required to verify actual APNs delivery.

## Properties verification — 0.5.0

40 package tests passed with the disposable HTTP/PostgreSQL fixture (none skipped).
Coverage includes local UUID generation before networking, Keychain restoration,
reset and namespace isolation, automatic collection without opening chat, collection
opt-outs, typed JSON validation, property failure isolation, and a legacy-server
bootstrap retry. Live HTTP tests verify custom-property merging/removal and the
local Barky ID appearing in the operator profile while chat restoration still works.
Four iOS Simulator UI tests passed for the existing SwiftUI/UIKit chat flows.
