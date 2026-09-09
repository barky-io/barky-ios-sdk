# Data handling

- By default, the SDK connects directly to Barky using a publishable SDK API key.
  It generates a cryptographically random installation credential, stores it in
  Keychain, and sends it only to the configured Barky API to create/renew its anonymous
  visitor session. This is not a hardware identifier or an advertising identifier.
  Short-lived session tokens stay in memory. An optional session provider supports
  verified users through the host application's authenticated backend.
- HTTPS is required, with an HTTP exception for loopback development. The SDK-owned
  ephemeral URLSession disables response caching/cookies and refuses redirects.
- In addition to the SDK key and installation credential, the SDK sends the message body, conversation subject, idempotency key, and
  the `messageContext` values explicitly configured by the host app. It does not
  automatically collect device identifiers, app versions, location, contacts, or files.
- Keychain stores the anonymous installation credential, conversation ID and at most one pending request, including its
  body, context, idempotency key and acknowledgement. Entries are scoped by API root,
  channel namespace and server-supplied customer ID. Access is when unlocked and on
  this device only. Confirmed message history is fetched into memory, not cached on disk.
- A failed or interrupted send is retained until retry succeeds or the host explicitly
  forgets local state. The retry uses the same logical payload and idempotency key.
  Uncertain sends are never silently discarded or automatically sent on app launch.
- The built-in chat UI sends IDs of support messages displayed in the active
  foreground viewport to the configured Barky API. The server records the first
  acknowledgement time for the operator's read indicator. Message bodies, scroll
  coordinates, and viewing durations are not included in receipt requests.
- Logout clears visible data and credentials, retaining local conversation continuity.
  `resetSession()` and `forgetLocalConversation()` remove the anonymous installation
  credential and current local conversation record, then disconnect. Reset before
  switching app accounts and handle any storage failure before continuing. Neither operation
  deletes data from the server. Keychain can persist across app reinstalls.
- There are no analytics, tracking, push registration, file uploads, or camera,
  microphone, and photo-library permission requests in this SDK.

`PrivacyInfo.xcprivacy` declares customer-support content, user identifiers, and
product interaction (message read receipts) for
app functionality, linked to the customer and not used for tracking. No required-reason
API categories are declared because this implementation does not use those APIs.
The host app must describe its own backend behavior and any extra values it chooses
to include in `messageContext`; the SDK cannot determine that usage.

Manifest schema references:
[Apple data-type values](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype),
[Apple manifest configuration](https://developer.apple.com/documentation/technotes/tn3184-adding-data-collection-details-to-your-privacy-manifest).
