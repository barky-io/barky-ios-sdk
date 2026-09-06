# Implementation provenance

The Barky SDK in this repository was written independently for Barky's own
customer-session and conversation HTTP API.

The following public product documentation was consulted for the integration flow:

- https://github.com/crisp-im/crisp-sdk-ios — SPM installation and presenting a chat view.
- https://docs.crisp.chat/guides/chatbox-sdks/ios-sdk/ — public SDK capabilities and presentation concepts.

No Crisp implementation source files, binary frameworks, assets, icons, fonts,
or localized strings were downloaded into or incorporated in this project.
There is no Crisp dependency. Shared platform conventions such as message bubbles,
a composer, SwiftUI views, and UIKit view controllers are implemented here using
Apple's system frameworks. Barky's colors, layout, and wording were authored for this SDK.

No third-party open-source dependency is included in the SDK product. The example
project generator optionally uses the locally installed `xcodeproj` development tool;
it is not linked into the SDK or app.

This SDK is distributed under the [MIT License](../LICENSE). The license applies
to the code and documentation in this repository; it does not apply to private
Barky backend code or grant rights to third-party trademarks.
