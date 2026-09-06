#if canImport(UIKit)
import SwiftUI

public struct ChatAppearance {
    public var title: String
    public var welcomeTitle: String
    public var welcomeMessage: String
    public var accentColor: Color
    public var outgoingTextColor: Color
    public var showsCloseButton: Bool

    public init(
        title: String? = nil,
        welcomeTitle: String? = nil,
        welcomeMessage: String? = nil,
        accentColor: Color = Color(red: 0.12, green: 0.36, blue: 0.29),
        outgoingTextColor: Color = .white,
        showsCloseButton: Bool = true
    ) {
        self.title = title ?? L10n.text("support")
        self.welcomeTitle = welcomeTitle ?? L10n.text("welcome.title")
        self.welcomeMessage = welcomeMessage ?? L10n.text("welcome.message")
        self.accentColor = accentColor
        self.outgoingTextColor = outgoingTextColor
        self.showsCloseButton = showsCloseButton
    }
}
#endif

import Foundation

enum L10n {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, comment: "")
    }
}
