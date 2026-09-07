# Barky iOS SDK

A native chat SDK that lets customers start a conversation directly in your app.
It provides a SwiftUI `ChatView` and a UIKit `ChatViewController` with no external package dependencies.

- iOS 16+ · Swift 5.9+ · Swift Package Manager
- Send and receive text messages, restore conversations, and retry failed sends
- Refresh customer sessions and poll for replies while the chat screen is active
- English and Korean localization, Dynamic Type, VoiceOver, and Dark Mode

Attachments, push notifications, read receipts, and agent online status are not supported.

English is the default language for this project's documentation.

## Installation

In Xcode, choose **File → Add Package Dependencies…**, enter the repository URL below,
select version `0.1.0` or later, and add the **Barky** product to your app target.

```text
https://github.com/barky-io/barky-ios-sdk.git
```

To use the SDK in another Swift package, add:

```swift
dependencies: [
    .package(url: "https://github.com/barky-io/barky-ios-sdk.git", from: "0.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "Barky", package: "barky-ios-sdk")
    ])
]
```

For local development, choose **Add Local…** and select this repository's folder.
The module name is `Barky`, and the package manifest is `Package.swift` at the repository root.

## SwiftUI usage

Configure the SDK once on the main actor, after your app can request a customer session
from its backend for the signed-in user. Set `apiURL` to your Barky API URL, including `/api/v1`.

```swift
import Barky
import SwiftUI

@MainActor
func configureSupport() throws {
    try BarkySDK.configure(BarkyConfiguration(
        apiURL: URL(string: "https://YOUR_BARKY_HOST/api/v1")!,
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

**Never embed a channel server key in your app.** The SDK accepts only `bk_session_` customer tokens.
To support anonymous users, your backend must first provide a verifiable anonymous user session.
Barky does not currently offer an API that issues tokens using only a public website ID.

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

When switching accounts or signing out, call this **before changing your app's user credentials**:

```swift
BarkySDK.logout()
// After the next user signs in, call configureSupport() again with their session provider.
```

Logout clears the chat UI, in-memory state, and credentials, and invalidates ongoing operations.
Keychain records remain available to restore the conversation if the same user returns.
To also remove the current user's local records, call `try BarkySDK.shared.forgetLocalConversation()`
instead of logout. This does not delete messages from the server. A message whose delivery outcome
is unknown may already have reached the server.

The current API does not list conversations for customers, so the SDK does not provide a conversation picker.
To restore a conversation across devices, your backend must verify ownership and include its `conversationId`
in the customer session response. Read the SDK's `conversationID` property to obtain the created conversation's ID.
An existing local conversation or a request awaiting retry takes precedence over the server-provided conversation ID.

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
