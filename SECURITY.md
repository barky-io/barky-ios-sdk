# Security

Report vulnerabilities privately using GitHub's
[Report a vulnerability](https://github.com/barky-io/barky-ios-sdk/security/advisories/new)
form. Do not include credentials, customer messages, or exploit details in public
issues. Include the SDK version, a minimal reproduction using synthetic data,
and the expected versus observed behavior.

Security fixes target the latest released version. Upgrade when a fix is published;
older versions do not have a separate maintenance commitment.

## Integration responsibilities

- Keep channel server keys on your authenticated backend. The app receives only
  short-lived customer sessions. The backend must derive the customer identity from
  the authenticated app user and enforce channel/customer isolation on every request.
- Use HTTPS. HTTP is accepted only for loopback development. SDK-created sessions
  reject redirects and disable response caching and cookies.
- Call `BarkySDK.logout()` before changing app users. A refreshed session returning
  a different customer ID invalidates visible state and outstanding work.
- The Keychain holds the current conversation ID and one pending send. Logout
  retains this local continuity record; use `forgetLocalConversation()` when it
  should also be removed. Neither operation deletes the server's records.
- Do not log customer tokens, message bodies, or session-provider responses.
  Values explicitly supplied as `messageContext` are sent to your Barky server.
- Custom URL protocols and session configuration are trusted host-app code. Use
  demo protocols only in testing; they are not a substitute for server authentication.

See [data handling](Documentation/Privacy.md) for the storage and privacy manifest
scope. Source review and automated tests reduce risk; they do not certify the SDK
or the host application's backend as free of vulnerabilities.
