# Push notifications

Barky can notify a customer when an operator posts a reply. Enable this separately
from chat: installing or configuring the SDK never prompts for notification permission,
registers with APNs, swizzles methods, or replaces your notification delegate.
Requires Barky SDK 0.4.0 or later and a Barky channel with push enabled.

## 1. Configure your iOS channel

In **Channels → your iOS App SDK channel → Push notifications**, choose **Sandbox**
for development-signed builds or **Production** for TestFlight/App Store builds.
Enter the app's Bundle ID, Apple Team ID, APNs Key ID, and upload the `.p8` private key.
The key must have APNs access for that app and environment. An App Store Connect API
key is a different credential and cannot send push notifications.

Save each environment separately. Barky encrypts the key on its server and never
returns it to the console or SDK. Keep your original key safely; replace the
configuration to rotate it. Removing a configuration deletes its device registrations
and queued notifications. Apps must register again after it is configured again.

In Xcode, add **Signing & Capabilities → Push Notifications** to your app target.
Use the APNs environment matching the signed `aps-environment` entitlement.
`#if DEBUG` is only a shortcut for a normal development signing configuration;
custom Debug distribution builds may still use Production. A background mode or
Notification Service Extension is not needed for these visible reply alerts.

## 2. Ask for permission in your app

Ask at a relevant point, such as after a customer chooses to contact support. The
host app owns the permission prompt and notification preferences.

```swift
import UIKit
import UserNotifications

@MainActor
func enableSupportNotifications() async throws {
    let granted = try await UNUserNotificationCenter.current()
        .requestAuthorization(options: [.alert, .badge, .sound])
    if granted { UIApplication.shared.registerForRemoteNotifications() }
}
```

On subsequent launches/foreground transitions, read notification settings and call
`registerForRemoteNotifications()` again when authorization permits. If permission
has been revoked, await `BarkySDK.disablePushNotifications()`. This removes only
Barky's registration; it does not disable your app's other notification services.

## 3. Forward the device token

Configure Barky before forwarding tokens. Add this to your existing app delegate;
SwiftUI apps can connect one using `@UIApplicationDelegateAdaptor`.

```swift
import Barky
import UIKit

func application(_ application: UIApplication,
                 didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Task { @MainActor in
        do {
            try await BarkySDK.registerForPushNotifications(
                deviceToken: deviceToken,
                environment: .sandbox // Use .production for TestFlight/App Store.
            )
        } catch {
            // Keep chat available. Retry registration with a fresh APNs token
            // after connectivity returns or on the next foreground transition.
        }
    }
}
```

The Bundle ID defaults to `Bundle.main.bundleIdentifier`. Tests or unusual host
arrangements can pass `bundleID:` explicitly. Do not pass an FCM token: Barky expects
the raw APNs `Data`. Device token length is variable. The SDK hex-encodes it without
assuming a fixed length and sends it using the private customer session.

Do not cache the APNs token in UserDefaults or your own persistent storage. Ask APNs
for the current token. The SDK persists only its registration handle and customer
binding in device-only Keychain, so it can unregister after an app restart.

## 4. Open chat when a notification is tapped

Keep your existing `UNUserNotificationCenterDelegate` and route Barky notifications
inside it. Set the delegate early during launch so cold-start taps are handled.

```swift
func userNotificationCenter(_ center: UNUserNotificationCenter,
                            didReceive response: UNNotificationResponse,
                            withCompletionHandler completionHandler: @escaping () -> Void) {
    let userInfo = response.notification.request.content.userInfo
    completionHandler()
    Task { @MainActor in
        do {
            if try await BarkySDK.handlePushNotification(userInfo) {
                // Set your SwiftUI presentation state or present ChatViewController().
                // Reuse the visible support screen if it is already open.
            } else {
                // Route unrelated notifications using your app's existing logic.
            }
        } catch {
            // Offer a retry when offline. An unsent draft in another conversation
            // is preserved and causes BarkyError.pendingMessage.
        }
    }
}
```

For foreground presentation, recognize a Barky payload with
`BarkyPushNotification(userInfo:)`. Your delegate decides whether to show a banner
or suppress it when support chat is already visible. Receiving or tapping an alert
does not mark a message read; read receipts still require visible chat content.

`handlePushNotification` validates the payload, checks the authenticated customer,
and requests the conversation from Barky before changing local chat state. An alert
from a previous account cannot open that account's messages. No API key, session
token, message text, or arbitrary URL is embedded in notification payloads.

## 5. Logout and notification opt-out

Before changing the app account or session provider, await cleanup and handle errors:

```swift
// Before changing identity:
try await BarkySDK.resetSessionWithPushCleanup()
// Now change the app account and configure Barky for the new customer.

// Or turn off only Barky notifications while keeping chat:
try await BarkySDK.disablePushNotifications()
```

A successful cleanup removes the server registration and queued deliveries. Network
failure means cleanup is unconfirmed: retry before changing the session provider.
The existing synchronous `logout()`, `resetSession()`, and client `invalidate()` can
only attempt best-effort push cleanup; they are not a substitute for the awaited API.
Already submitted APNs alerts cannot be recalled, so alerts use a generic reply
notice instead of conversation text. The SDK does not log tokens or key material.

## Delivery behavior and testing

Only customer-visible operator replies trigger notifications. Internal notes and
customer messages do not. Barky skips jobs for replies already acknowledged as read,
removed registrations, disabled channels, and expired devices. A registered device
expires after 90 days without registration. APNs acceptance is not delivery or reading.

Transient failures are retried up to eight attempts within 24 hours. APNs may retain
an accepted alert for up to one hour while a device is offline. Retries use the same
APNs ID and a conversation collapse ID; delivery remains at least once and multiple
replies may coalesce. A timeout can leave acceptance uncertain.

1. Save the correct channel configuration and run a signed app with push capability.
2. Allow notifications and forward a fresh device token.
3. Send a chat message, put the app in the background, and reply from the Barky Inbox.
4. Confirm the generic alert and tap it to reopen the authenticated conversation.
5. Test foreground banners, a terminated app, denied permission, token renewal,
   temporary network loss, Sandbox/Production mismatch, and logout/account changes.

Simulator routing or mocked provider tests do not prove APNs delivery. Verify the
full flow on your intended signed device/build and environment.

## Apple references

- [Registering your app with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)
- [Establishing a token-based connection to APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)
- [Sending notification requests to APNs](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)
