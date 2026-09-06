# Verification

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
