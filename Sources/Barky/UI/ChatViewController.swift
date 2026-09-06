#if canImport(UIKit)
import SwiftUI
import UIKit

/// UIKit presentation: present(ChatViewController(), animated: true).
@MainActor
public final class ChatViewController: UIHostingController<ChatView> {
    public init(client: BarkyClient? = nil, appearance: ChatAppearance = ChatAppearance()) {
        super.init(rootView: ChatView(client: client, appearance: appearance))
    }

    @available(*, unavailable)
    required dynamic init?(coder aDecoder: NSCoder) { fatalError("Use init(client:appearance:)") }
}
#endif
