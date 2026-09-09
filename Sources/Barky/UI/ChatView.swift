#if canImport(UIKit)
import SwiftUI

/// A complete, self-contained chat screen. Present in a sheet, full-screen cover,
/// or navigation destination. No pre-chat form or first-message API call is needed.
@MainActor
public struct ChatView: View {
    @ObservedObject private var client: BarkyClient
    private let appearance: ChatAppearance
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var observer = UUID()
    @State private var isAtBottom = true
    @State private var previousMessageCount = 0
    @State private var isVisible = false
    @State private var messageFrames: [String: CGRect] = [:]
    @State private var viewportSize = CGSize.zero
    @FocusState private var composerFocused: Bool

    public init(client: BarkyClient? = nil, appearance: ChatAppearance = ChatAppearance()) {
        self.client = client ?? BarkySDK.shared
        self.appearance = appearance
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
        }
        .background(Color(uiColor: .systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .tint(appearance.accentColor)
        .onAppear {
            isVisible = true
            client.setVisible(scenePhase == .active, observer: observer)
            updateReadVisibility()
        }
        .onDisappear {
            isVisible = false
            client.setVisible(false, observer: observer)
        }
        .onChange(of: scenePhase) { phase in
            client.setVisible(isVisible && phase == .active, observer: observer)
            updateReadVisibility()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.title3)
                .foregroundStyle(appearance.accentColor)
                .frame(width: 44, height: 44)
                .background(appearance.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(appearance.title).font(.headline)
                Text(L10n.text("conversation.private"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if appearance.showsCloseButton {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.medium))
                        .foregroundStyle(.secondary).frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .accessibilityLabel(L10n.text("close"))
                .accessibilityIdentifier("barky.close")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var transcript: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 20) {
                        if client.messages.isEmpty && client.pending == nil {
                            welcome
                        }
                        ForEach(Array(client.messages.enumerated()), id: \.element.id) { index, message in
                            if index == 0 || !Calendar.current.isDate(client.messages[index - 1].createdAt, inSameDayAs: message.createdAt) {
                                Text(message.createdAt, format: .dateTime.month(.abbreviated).day())
                                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
                            }
                            messageBubble(body: message.body, isCustomer: message.isFromCustomer,
                                          date: message.createdAt, delivery: nil)
                                .id(message.id)
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: MessageFramesKey.self,
                                        value: [message.id: geometry.frame(in: .named(observer))])
                                })
                        }
                        if let pending = client.pending,
                           !client.messages.contains(where: { $0.id == pending.messageID }) {
                            VStack(alignment: .trailing, spacing: 8) {
                                messageBubble(body: pending.body, isCustomer: true, date: pending.createdAt,
                                              delivery: L10n.text(client.isSending ? "sending" : pending.messageID == nil ? "send.failed" : "sent"))
                                if !client.isSending && pending.messageID == nil {
                                    Button(L10n.text("retry.send")) { client.retryPendingMessage() }
                                        .font(.callout.weight(.semibold)).frame(minHeight: 44)
                                        .accessibilityIdentifier("barky.retrySend")
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .onAppear { isAtBottom = true }
                            .onDisappear { isAtBottom = false }
                    }
                    .padding(20)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable { await client.refresh() }
                .overlay(alignment: .bottomTrailing) {
                    if !isAtBottom && !client.messages.isEmpty {
                        Button {
                            scrollToBottom(proxy)
                        } label: {
                            Image(systemName: "arrow.down").frame(width: 44, height: 44)
                                .background(.regularMaterial, in: Circle())
                        }
                        .accessibilityLabel(L10n.text("latest"))
                        .padding(16)
                    }
                }
                .onChange(of: client.messages.count) { count in
                    if isAtBottom || previousMessageCount == 0 { scrollToBottom(proxy) }
                    previousMessageCount = count
                }
                .onChange(of: client.pending?.key) { _ in scrollToBottom(proxy) }
                .onChange(of: composerFocused) { focused in
                    if focused { scrollToBottom(proxy) }
                }
                .accessibilityIdentifier("barky.messages")
                .coordinateSpace(name: observer)
                .onPreferenceChange(MessageFramesKey.self) { frames in
                    messageFrames = frames
                    viewportSize = viewport.size
                    updateReadVisibility()
                }
                .onChange(of: viewport.size) { size in
                    viewportSize = size
                    updateReadVisibility()
                }
            }
        }
    }

    private func updateReadVisibility() {
        guard isVisible, scenePhase == .active else { return }
        let viewport = CGRect(origin: .zero, size: viewportSize)
        let ids = Set(messageFrames.filter { MessageVisibility.isReadable($0.value, in: viewport) }.keys)
        client.setVisibleMessages(ids, observer: observer)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "hand.wave")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(appearance.accentColor).accessibilityHidden(true)
            Text(appearance.welcomeTitle).font(.largeTitle.weight(.semibold))
            Text(appearance.welcomeMessage).font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if client.isLoading && !client.isReady {
                ProgressView().padding(.top, 6).accessibilityLabel(L10n.text("loading"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 44)
    }

    private func messageBubble(body: String, isCustomer: Bool, date: Date, delivery: String?) -> some View {
        HStack(alignment: .bottom, spacing: 12) {
            if isCustomer { Spacer(minLength: 32) }
            VStack(alignment: isCustomer ? .trailing : .leading, spacing: 6) {
                if !isCustomer { Text(appearance.title).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
                Text(body)
                    .font(.body)
                    .textSelection(.enabled)
                    .foregroundStyle(isCustomer ? appearance.outgoingTextColor : .primary)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(isCustomer ? appearance.accentColor : Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 20))
                HStack(spacing: 6) {
                    Text(date, style: .time)
                    if let delivery { Text(delivery) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            if !isCustomer { Spacer(minLength: 32) }
        }
        .accessibilityElement(children: .combine)
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if let error = client.lastError {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                    Text(errorText(error)).font(.footnote)
                    Spacer(minLength: 0)
                    Button(L10n.text("retry")) { Task { await client.refresh() } }
                        .font(.footnote.weight(.semibold)).frame(minHeight: 44)
                        .accessibilityIdentifier("barky.retryConnection")
                }
                .padding(.horizontal, 20).padding(.vertical, 4)
                .background(Color(uiColor: .secondarySystemBackground))
            }
            Divider()
            HStack(alignment: .bottom, spacing: 12) {
                TextField(L10n.text("message.placeholder"), text: $client.draft, axis: .vertical)
                    .lineLimit(1...5).font(.body).padding(.vertical, 12).padding(.leading, 16)
                    .focused($composerFocused)
                    .accessibilityLabel(L10n.text("message.placeholder"))
                    .accessibilityIdentifier("barky.composer")
                Button { client.send() } label: {
                    Image(systemName: "arrow.up").font(.body.weight(.semibold))
                        .foregroundStyle(appearance.outgoingTextColor)
                        .frame(width: 44, height: 44)
                        .background(appearance.accentColor, in: Circle())
                        .opacity(canSend ? 1 : 0.35)
                }
                .disabled(!canSend)
                .accessibilityLabel(L10n.text("send"))
                .accessibilityIdentifier("barky.send")
                .padding(4)
            }
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 27))
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            if client.draft.utf16.count > 10_000 {
                Text(L10n.text("message.limit")).font(.caption).foregroundStyle(.red).padding(.bottom, 8)
            }
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var canSend: Bool {
        client.isReady && !client.isSending && client.pending == nil &&
        !client.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && client.draft.utf16.count <= 10_000
    }

    private func errorText(_ error: Error) -> String {
        switch error as? BarkyError {
        case .notConfigured, .invalidConfiguration: return L10n.text("error.configuration")
        case .invalidSession, .identityChanged, .http(status: 401, code: _): return L10n.text("error.session")
        case .http(status: 404, code: _): return L10n.text("error.unavailable")
        case .invalidMessage: return L10n.text("message.limit")
        case .storageUnavailable: return L10n.text("error.storage")
        default: return L10n.text("error.connection")
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }
}

private struct MessageFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
#endif
