# Barky iOS SDK

A native chat SDK that lets customers start a conversation directly in your app.
It provides a SwiftUI `ChatView` and a UIKit `ChatViewController` with no external package dependencies. Connect directly to Barky with an SDK API key; no application backend is required.

- iOS 16+ · Swift 5.9+ · Swift Package Manager
- Send and receive text messages, restore conversations, and retry failed sends
- Refresh customer sessions and poll for replies while the chat screen is active
- Acknowledge visible support replies so operators can see their read status
- English and Korean localization, Dynamic Type, VoiceOver, and Dark Mode

Attachments, push notifications, and agent online status are not supported.

English is the default language for this project's documentation.

## Installation

In Xcode, choose **File → Add Package Dependencies…**, enter the repository URL below,
select version `0.3.0` or later, and add the **Barky** product to your app target.

```text
https://github.com/barky-io/barky-ios-sdk.git
```

To use the SDK in another Swift package, add:

```swift
dependencies: [
    .package(url: "https://github.com/barky-io/barky-ios-sdk.git", from: "0.3.0")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "Barky", package: "barky-ios-sdk")
    ])
]
```

For local development, choose **Add Local…** and select this repository's folder.
The module name is `Barky`, and the package manifest is `Package.swift` at the repository root.

## Quick start

1. Open **Channels** in the Barky console and create an **iOS App SDK** channel.
2. Open the channel’s **Channel setup** page and copy its `bk_sdk_…` SDK API key.
3. Configure once on the main actor when your app starts, then present `ChatView()`.

The SDK API key is designed to be included in your app. It only bootstraps anonymous
visitor sessions; it cannot access the console, issue verified-user sessions, or read
another visitor's messages. Use a channel from the intended environment.

```swift
import Barky
import SwiftUI

@MainActor
func configureSupport() throws {
    try BarkySDK.configure(BarkyConfiguration(
        apiKey: "YOUR_SDK_API_KEY"
    ))
}

struct SupportButton: View {
    @State private var showsChat = false

    var body: some View {
        Button("Contact support") { showsChat = true }
            .sheet(isPresented: $showsChat) {
                ChatView()
            }
    }
}
```

The SDK connects to Barky automatically; no API URL configuration is required.
It creates a random, private installation credential and saves it in this device's Keychain before the
first request. Barky uses it to create and refresh the visitor's short-lived session.
No customer backend, server key, login, or session-provider callback is needed.

SDK keys and Custom API server keys are different credentials. Never substitute a
`bk_channel_…` server key for an SDK key. Disabling the SDK channel rejects subsequent
session creation and message requests.

For development and tests, the optional `apiURL` initializer argument can override
the service endpoint. Normal app integrations only need an SDK API key.

## Read receipts

`ChatView` and `ChatViewController` automatically acknowledge support replies that
remain visible for at least half a second while the chat is active in the foreground.
At least half the bubble must intersect the message viewport; for replies taller
than the viewport, half the viewport is sufficient. Merely downloading a message,
prefetching a row, or opening the chat in the background does not mark it read.

The SDK posts batches of visible message IDs to
`POST /conversations/{id}/read-receipts` using the private customer session.
Barky records the first acknowledgement time and the Inbox changes `Sent` to `Read`.
`Sent` means the reply is saved and available to the customer; it does not imply
delivery or reading. Existing messages are acknowledged when viewed with this SDK;
old clients cannot report historical reading times.

Receipt failures retry with backoff while the messages remain visible and do not
block sending. Closing the chat or backgrounding cancels pending receipt work.
Unconfirmed receipts are not persisted across app termination; reopening visible
messages retries safely. Read status indicates display, not proof of comprehension.
A custom UI built directly on `BarkyClient.refresh()` does not automatically report reads.

## UIKit and appearance

```swift
// UIKit: call on the main actor.
present(ChatViewController(), animated: true)

// SwiftUI
ChatView(appearance: ChatAppearance(
    title: "Customer support",
    welcomeTitle: "Hello!",
    welcomeMessage: "Send us a message. We're here to help.",
    accentColor: .indigo
))
```

The chat screen includes its own header and close button. If your app provides navigation,
hide the close button with `ChatAppearance(showsCloseButton: false)`.
When choosing custom colors, check their contrast with `outgoingTextColor`.

The SDK includes English and Korean resources. If your app does not declare these languages,
add `CFBundleAllowMixedLocalizations = YES` to the app's Info.plist so the SDK can select
its localization based on the device language. The example app includes this setting.

To use a separate client instance, create it with `try BarkyClient(configuration: configuration)`
and pass it to `ChatView(client: client)` or `ChatViewController(client: client)`.
Share one client for the same customer and channel.

## Conversation lifecycle and logout

Customers can compose a message as soon as they open an empty chat screen. The first send creates
a conversation, and subsequent messages are added to it. Per-customer Keychain records restore
the conversation when the screen is reopened or the app is relaunched.
Polling stops when the screen closes or the app enters the background. Sends already in progress may complete.

Before switching app accounts or starting a new anonymous visitor, reset local access:

```swift
try BarkySDK.resetSession()
// Handle a storage error before changing accounts. Configure again for the next visitor.
```

Reset removes the installation credential, local conversation reference, and pending
send, then clears the UI and cancels ongoing work. It does not delete server messages;
a send with an uncertain outcome may already have reached Barky. Retrying a failed
reset is safe. `forgetLocalConversation()` has the same behavior.

`BarkySDK.logout()` only disconnects and clears visible/in-memory state. It preserves
local continuity, so configuring again resumes the same anonymous visitor. Use
`resetSession()` when the next app user must not inherit that visitor's conversation.

Anonymous conversations are restored on the same device. Keychain data can survive
app reinstalls, but is not synced to other devices. There is no conversation picker.
For verified users and server-assisted cross-device restoration, see the optional
integration below. Its session provider can include an ownership-verified `conversationId`;
existing local conversation or pending retry state takes precedence.

## Example app and testing

Open `Examples/BarkyDemo/BarkyDemo.xcodeproj` and run **BarkyDemo**.
The example references the local Swift package and uses a demo transport that works without a server.
Use "Fail the next send" to try the failure and retry UI. Simulated replies are confined to the example app.

Run the core tests with:

```sh
swift test
```

The core tests cover authentication, pagination, network failures, request deduplication, storage errors,
account changes, and conversation restoration. Live server integration tests are skipped when their
environment variables are not set. See [Testing](Documentation/Testing.md) for additional coverage
and instructions for running the iOS UI tests.

## Provenance and data handling

Crisp's [public README](https://github.com/crisp-im/crisp-sdk-ios) served only as a reference for
the integration flow: install with SPM, configure the SDK, and open a chat screen.
No Crisp implementation source, binaries, images, icons, or strings were incorporated, and Crisp is not a dependency.
The UI was implemented independently with SwiftUI and system SF Symbols.

See [Privacy](Documentation/Privacy.md) for data storage, transmission, and privacy manifest details.
The SDK is distributed under the [MIT License](LICENSE). References and implementation origins
are documented in [Provenance](Documentation/Provenance.md).

## Verified user sessions (optional)

For server-verified user identities, create a **Custom API** channel instead of an iOS App SDK channel. This optional mode uses your existing authenticated backend to issue sessions. Configure the SDK once on the main actor, after sign-in.

```swift
import Barky
import SwiftUI

@MainActor
func configureSupport() throws {
    try BarkySDK.configure(BarkyConfiguration(
        storageNamespace: "YOUR_CHANNEL_ID"
    ) {
        // Implement this method using your app's authenticated networking layer.
        // Decode the backend response with JSONDecoder().decode(BarkySession.self, from: data).
        try await AppBackend.fetchBarkySession()
    })
}

struct SupportButton: View {
    @State private var showsChat = false

    var body: some View {
        Button("Contact support") { showsChat = true }
            .sheet(isPresented: $showsChat) {
                ChatView()
            }
    }
}
```

`AppBackend.fetchBarkySession()` is an integration point that your app implements.
The session provider is called on initial connection, when a request needs a session with
30 seconds or less remaining before expiry, and after an HTTP 401 response. Always return
**a fresh customer session for the currently authenticated user**.
The SDK makes no assumptions about your app's authentication method or backend URL.

Your backend must determine the authenticated user's ID itself, then call
`POST /api/v1/customer-sessions` using a channel key stored on the server.
Return a response in this format to the app:

```json
{
  "token": "bk_session_…",
  "customerId": "customer-uuid",
  "expiresAt": "2026-09-06T10:00:00.000Z"
}
```

**Never embed a channel server key in your app.** The optional session provider must return a `bk_session_` customer token.
For anonymous visitors, use the SDK API key setup above. Do not embed a Custom API server key in an app.
