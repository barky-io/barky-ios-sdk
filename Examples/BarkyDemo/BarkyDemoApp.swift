import Barky
import SwiftUI

@main
struct BarkyDemoApp: App {
    init() {
        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [DemoProtocol.self]
        do {
            try BarkySDK.configure(BarkyConfiguration(
                apiKey: "bk_sdk_" + String(repeating: "d", count: 43), pollingInterval: 1
            ), urlSessionConfiguration: transport)
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                try BarkySDK.resetSession()
                try BarkySDK.configure(BarkyConfiguration(
                    apiKey: "bk_sdk_" + String(repeating: "d", count: 43), pollingInterval: 1
                ), urlSessionConfiguration: transport)
            }
        } catch { assertionFailure("Invalid demo configuration") }
    }

    var body: some Scene {
        WindowGroup { DemoHome() }
    }
}

struct DemoHome: View {
    @State private var showChat = ProcessInfo.processInfo.arguments.contains("--show-chat")
    @State private var directUIKitReadLabel: UILabel?
    @State private var notificationPrepared = false
    @State private var notificationRead = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Text("Barky").font(.largeTitle.bold())
                Text("A conversation, right inside your app.").font(.title2)
                Text("SDK demo · Responses are generated on this device. No messages are sent to a server.")
                    .font(.body).foregroundStyle(.secondary)
                Button("Open chat demo") { showChat = true }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("demo.openChat")
                Button("Open UIKit demo") { presentUIKitDemo() }
                    .buttonStyle(.bordered).accessibilityIdentifier("demo.openUIKit")
                Button("Fail the next send") { DemoProtocol.failNextSend() }
                    .buttonStyle(.bordered).accessibilityIdentifier("demo.failNext")
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                    Button("Prepare notification conversation") {
                        Task {
                            notificationPrepared = (try? await BarkySDK.handlePushNotification(
                                DemoProtocol.prepareNotificationConversation())) == true
                        }
                    }
                    .accessibilityIdentifier("demo.prepareNotification")
                    if notificationPrepared { Text("Notification conversation ready") }
                }
                Spacer()
                Text("Swift Package Manager · iOS 16+").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(28)
            .sheet(isPresented: $showChat) {
                ChatView(appearance: ChatAppearance(title: "Barky Demo"))
            }
            .onReceive(NotificationCenter.default.publisher(for: DemoProtocol.notificationRead)
                .receive(on: DispatchQueue.main)) { _ in
                    notificationRead = true
                    directUIKitReadLabel?.text = "Notification reply read"
                }
        }
    }

    private func presentUIKitDemo() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var presenter = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        while let presented = presenter.presentedViewController { presenter = presented }
        let controller = ChatViewController(appearance: ChatAppearance(title: "Barky UIKit Demo"))
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), notificationPrepared {
            let label = UILabel()
            label.text = notificationRead ? "Notification reply read" : "Waiting for read receipt"
            label.font = .preferredFont(forTextStyle: .caption1)
            label.translatesAutoresizingMaskIntoConstraints = false
            controller.view.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor),
                label.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            ])
            directUIKitReadLabel = label
        }
        presenter.present(controller, animated: true)
    }
}
