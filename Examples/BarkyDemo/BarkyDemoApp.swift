import Barky
import SwiftUI

@main
struct BarkyDemoApp: App {
    init() {
        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [DemoProtocol.self]
        do {
            try BarkySDK.configure(BarkyConfiguration(
                apiURL: URL(string: "https://demo.barky.invalid/api/v1")!,
                apiKey: "bk_sdk_" + String(repeating: "d", count: 43), pollingInterval: 1
            ), urlSessionConfiguration: transport)
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                try BarkySDK.resetSession()
                try BarkySDK.configure(BarkyConfiguration(
                    apiURL: URL(string: "https://demo.barky.invalid/api/v1")!,
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
    @State private var showUIKit = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Text("Barky").font(.largeTitle.bold())
                Text("A conversation, right inside your app.").font(.title2)
                Text("SDK demo · Responses are generated on this device. No messages are sent to a server.")
                    .font(.body).foregroundStyle(.secondary)
                Button("Open chat demo") { showChat = true }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("demo.openChat")
                Button("Open UIKit demo") { showUIKit = true }
                    .buttonStyle(.bordered).accessibilityIdentifier("demo.openUIKit")
                Button("Fail the next send") { DemoProtocol.failNextSend() }
                    .buttonStyle(.bordered).accessibilityIdentifier("demo.failNext")
                Spacer()
                Text("Swift Package Manager · iOS 16+").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(28)
            .sheet(isPresented: $showChat) { ChatView(appearance: ChatAppearance(title: "Barky Demo")) }
            .sheet(isPresented: $showUIKit) { UIKitChat() }
        }
    }
}

struct UIKitChat: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ChatViewController {
        ChatViewController(appearance: ChatAppearance(title: "Barky UIKit Demo"))
    }
    func updateUIViewController(_ controller: ChatViewController, context: Context) {}
}
