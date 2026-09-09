# Customer and device properties

Barky 0.5.0 collects support context when you configure the SDK, without waiting for
the customer to open chat. The Inbox's **Customer details** panel separates:

- **Barky ID**: a random UUID generated locally by the SDK (`BarkySDK.barkyID`).
  It identifies this anonymous visitor/installation and is bound to the private
  customer session on the server. It is not the server database ID or a credential.
- **System properties**: SDK-collected device/app information, the local Barky ID, and server-recorded first/last property-sync timestamps.
- **User properties**: custom JSON properties you set for the current customer.
- **Device properties**: custom JSON properties for this customer on this installation.
- **IP location**: approximate country, region and city derived by Barky's hosting
  ingress from the request IP, separately from the device's locale region.
- **Verified properties**: attributes supplied through the private server API.
  SDK properties never overwrite these or verify a customer's identity.

## Automatic fields

| Field | Meaning |
| --- | --- |
| `device_model` | Device family from the OS, such as `iPhone` or `iPad` |
| `device_model_identifier` | Hardware model code, such as `iPhone18,1`; not a unique hardware ID or a marketing-name lookup |
| `device_manufacturer` | `Apple` |
| `platform`, `os_name`, `os_version` | Platform and operating system version |
| `app_bundle_id`, `app_version`, `app_build` | Host app's bundle identifier, version and build, when available |
| `sdk_version` | Barky SDK version |
| `language`, `languages` | First preferred language and up to 20 preferred language tags |
| `locale`, `region` | Device locale and locale region; these do not establish physical location |
| `timezone` | Current time-zone identifier |
| `is_simulator` | Whether the SDK is running in a Simulator |
| `barky_id` | Locally generated UUID stored in device-only Keychain; separate from private credentials |
| `first_seen`, `last_seen` | Server timestamps for visitor registration/property syncs, not precise online presence |

The SDK does not read GPS, IDFA, IDFV, the user's device name, contacts, photos,
or files. It does not call an external location API. Barky stores country/region/city
in the profile, not the raw IP or latitude/longitude. Network infrastructure may
process IP addresses to serve requests according to the service's own policies.
IP location can be missing or reflect a VPN/proxy. Localhost and self-hosted servers
without a trusted geolocation source show no IP location; no location is guessed.

## Set custom properties

Call on the main actor after configuration. Await completion to handle failures.
Values support JSON strings, numbers, booleans, arrays, objects, and null.

```swift
try await BarkySDK.setUserProperties([
    "plan": "pro",
    "preferred_support_language": "en",
    "onboarding_completed": true,
    "tags": ["beta", "annual"]
])
try await BarkySDK.setDeviceProperties([
    "appearance": "dark",
    "notifications_enabled": true
])

// Merge changes. Omitted keys remain unchanged; top-level null removes a key.
try await BarkySDK.setUserProperties(["plan": "team", "tags": .null])
try await BarkySDK.syncProperties()
let supportReference = BarkySDK.barkyID
```

These APIs are also available on an explicitly owned `BarkyClient`. Setting a
custom property named `user_id` does not switch accounts or link anonymous visitors.
Do not use client-supplied properties for authorization or billing decisions.

Each custom property group allows 100 keys and 8 KB of UTF-8 JSON, including the
merged stored result. Keys must be 1–100 UTF-16 units; JSON nesting is limited to
five levels. Names beginning with `$` or `barky_`, and `__proto__`, `constructor`,
and `prototype`, are reserved. Numbers must be finite. Validation errors throw
`BarkyError.invalidProperties` locally or an HTTP error for server-side limits.
A customer can have up to 20 device records per channel.

Custom updates are serialized in call order on each client. The server merges
patches atomically; the last successful write to a key wins. An acknowledged update
persists on the server. Failed custom updates are thrown to the caller and are not
queued on disk; retry the same patch explicitly. Never include passwords, payment
credentials, session tokens, or unnecessary personal data.

## Collection controls and timing

Both automatic system collection and approximate IP location are enabled by default.
To wait for your app's consent flow, set the controls before configuration:

```swift
try BarkySDK.configure(BarkyConfiguration(
    apiKey: "YOUR_SDK_API_KEY",
    propertyCollection: .disabled
))
```

To collect device/app information without IP location:

```swift
try BarkySDK.configure(BarkyConfiguration(
    apiKey: "YOUR_SDK_API_KEY",
    propertyCollection: .init(systemProperties: true, ipLocation: false)
))
```

Automatic sync runs at configuration and eligible foreground/chat refreshes, at
most once per minute. It does not run a background timer. `syncProperties()` and
custom setters send immediately. Automatic errors appear in
`BarkySDK.shared.propertySyncError` and retry on a later eligible refresh. Property
failures do not block chat. `barkyID` is available immediately after API-key configuration, even offline.
With a custom session provider it becomes available after authentication, so local
IDs remain isolated by the verified customer. Disconnect clears the in-memory value
and retains its stored value for restoration.

When system collection is off, an explicit device update sends an empty system
snapshot. When IP collection is off, a device update clears its stored location.
Disabling both stops automatic uploads; it does not retroactively delete server
records. Explicit user-only updates with collection disabled send the local Barky ID and
custom user values, without device metadata or location. Explicit `syncProperties()`
can register the local ID even when automatic collection is disabled.

The anonymous Barky ID survives app launches through Keychain, which
may survive reinstalls. API URLs, channel namespaces, and customer IDs isolate local
records. Before switching app accounts, await `resetSessionWithPushCleanup()` (or
`resetSession()` without push), then configure again. Reset rotates the local
Barky ID and private installation credential; logout alone retains continuity. Neither deletes server data.

Review [data handling](Privacy.md) and your app's privacy disclosures before shipping.
ID lifecycle follows the restore-or-create pattern documented in the
[Amplitude iOS Swift SDK](https://www.amplitude.com/docs/sdks/analytics/ios/ios-swift-sdk).
Barky uses a random UUID rather than IDFV/IDFA. The same stored ID is reused after
relaunch and normal logout; explicit reset creates a new UUID. Knowing an ID cannot
resume a customer session: the private installation credential is still required.
A new device starts a separate anonymous visitor. With a verified session provider,
multiple local Barky IDs can belong to the same verified customer; the Inbox lists
each device and shows the most recently seen Barky ID at the top.

Default-property organization was informed by
[Amplitude's published definitions](https://amplitude.com/docs/get-started/user-property-definitions);
the implementation is original and has no Amplitude dependency.

Older Barky servers may reject the new bootstrap field. The SDK retries that
specific validation response once using the existing private installation credential,
preserving chat during a rolling upgrade. It retains the local Barky ID and binds it
through property sync when the server supports properties. Binding conflicts are
never retried as legacy requests.
