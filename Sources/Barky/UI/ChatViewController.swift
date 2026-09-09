#if canImport(UIKit)
import Combine
import SwiftUI
import UIKit

@MainActor
final class ChatSceneActivity: ObservableObject {
    @Published private(set) var isActive: Bool?

    init(isActive: Bool? = nil) { self.isActive = isActive }

    func setActive(_ active: Bool) {
        if isActive != active { isActive = active }
    }
}

/// UIKit presentation: present(ChatViewController(), animated: true).
@MainActor
public final class ChatViewController: UIHostingController<ChatView> {
    private var hasAppeared = false
    private let sceneActivity = ChatSceneActivity(isActive: false)
    private var lifecycleObservers = Set<AnyCancellable>()

    public init(client: BarkyClient? = nil, appearance: ChatAppearance = ChatAppearance()) {
        super.init(rootView: ChatView(client: client, appearance: appearance, sceneActivity: sceneActivity))
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification,
                     UIScene.didEnterBackgroundNotification, UIScene.didDisconnectNotification,
                     UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] notification in self?.updateSceneActivity(notification) }
                .store(in: &lifecycleObservers)
        }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        updateSceneActivity()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        hasAppeared = false
        sceneActivity.setActive(false)
        super.viewWillDisappear(animated)
    }

    private func updateSceneActivity(_ notification: Notification? = nil) {
        guard hasAppeared, let window = viewIfLoaded?.window else {
            sceneActivity.setActive(false)
            return
        }
        if notification?.name == UIApplication.willResignActiveNotification ||
            notification?.name == UIApplication.didEnterBackgroundNotification {
            sceneActivity.setActive(false)
            return
        }
        if let scene = window.windowScene {
            // willDeactivate arrives before activationState necessarily changes.
            let deactivating = notification?.name == UIScene.willDeactivateNotification &&
                (notification?.object as? UIScene) === scene
            sceneActivity.setActive(!deactivating && scene.activationState == .foregroundActive)
        } else {
            // UIKit applications can still opt out of the scene lifecycle.
            sceneActivity.setActive(UIApplication.shared.applicationState == .active)
        }
    }

    @available(*, unavailable)
    required dynamic init?(coder aDecoder: NSCoder) { fatalError("Use init(client:appearance:)") }
}
#endif
