# Security

Report vulnerabilities privately using GitHub's
[Report a vulnerability](https://github.com/barky-io/barky-ios-sdk/security/advisories/new)
form. Do not include credentials, customer messages, or exploit details in public
issues. Include the SDK version, a minimal reproduction using synthetic data,
and the expected versus observed behavior.

Security fixes target the latest released version. Upgrade when a fix is published;
older versions do not have a separate maintenance commitment.

## Integration responsibilities

- Use a `bk_sdk_…` SDK API key for direct app integration. This publishable key
  bootstraps anonymous sessions; it cannot read conversations or administer Barky.
  A private, random installation credential proves continuity for each visitor.
- The optional verified-user integration uses a Custom API server key on your
  authenticated backend. Never include a `bk_channel_…` server key in an app.
- Use HTTPS. HTTP is accepted only for loopback development. SDK-created sessions
  reject redirects and disable response caching and cookies.
- Call `try BarkySDK.resetSession()` before changing app users in direct SDK mode,
  handling any storage error before continuing. In verified-user mode, call
  `BarkySDK.logout()` before changing the provider's user. A refreshed session returning
  a different customer ID invalidates visible state and outstanding work.
- The Keychain holds the installation credential, current conversation ID and one pending send. Logout
  retains this local continuity record; use `forgetLocalConversation()` when it
  should also be removed. Neither operation deletes the server's records.
- Do not log installation credentials, customer tokens, message bodies, or session-provider responses.
  Values explicitly supplied as `messageContext` are sent to your Barky server.
- Custom URL protocols and session configuration are trusted host-app code. Use
  demo protocols only in testing; they are not a substitute for server authentication.

See [data handling](Documentation/Privacy.md) for the storage and privacy manifest
scope. Source review and automated tests reduce risk; they do not certify the SDK
or the host application's backend as free of vulnerabilities.
