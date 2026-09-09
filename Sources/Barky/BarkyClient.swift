import Combine
import Foundation

/// One customer conversation. Own a client explicitly, or use BarkySDK.configure.
/// All presentation and lifecycle methods run on the main actor.
@MainActor
public final class BarkyClient: ObservableObject {
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var conversationID: String?
    @Published public private(set) var conversationStatus: String?
    @Published public private(set) var isLoading = false
    @Published public private(set) var isSending = false
    @Published public private(set) var isReady = false
    @Published public private(set) var lastError: Error?
    @Published public var draft = ""
    @Published private(set) var pending: PendingMessage?

    private var api: BarkyAPI?
    private let storage: ChatStorage
    private var storageKey: String?
    private var cursor = 0
    private var generation = UUID()
    private var observers = Set<UUID>()
    private var polling: Task<Void, Never>?
    private var sending: Task<Void, Never>?

    public convenience init(configuration: BarkyConfiguration, urlSessionConfiguration: URLSessionConfiguration? = nil) throws {
        try self.init(configuration: configuration, storage: KeychainChatStorage(), sessionConfiguration: urlSessionConfiguration)
    }

    init(configuration: BarkyConfiguration? = nil, storage: ChatStorage, session: URLSession? = nil,
         sessionConfiguration: URLSessionConfiguration? = nil) throws {
        self.storage = storage
        if let configuration {
            try configuration.validate()
            api = BarkyAPI(configuration: configuration, session: session, sessionConfiguration: sessionConfiguration, storage: storage)
        }
    }

    deinit { polling?.cancel(); sending?.cancel() }

    func configure(_ configuration: BarkyConfiguration, sessionConfiguration: URLSessionConfiguration? = nil) throws {
        try configuration.validate()
        invalidate()
        api = BarkyAPI(configuration: configuration, sessionConfiguration: sessionConfiguration, storage: storage)
        restartPolling()
    }

    /// Call on logout/account changes, before changing the session provider's user.
    /// Cancels work and clears visible data and credentials. It does not delete the
    /// customer's server conversation or the Keychain record needed for restoration.
    public func invalidate() {
        generation = UUID()
        polling?.cancel(); polling = nil
        sending?.cancel(); sending = nil
        api?.invalidate(); api = nil
        storageKey = nil
        messages = []; conversationID = nil; conversationStatus = nil
        draft = ""; pending = nil; cursor = 0
        isReady = false; isSending = false; isLoading = false; lastError = nil
    }

    /// Remove the current customer's local conversation and pending send, then sign
    /// out of the SDK. An uncertain send may already exist on the server.
    public func forgetLocalConversation() throws {
        try resetSession()
    }

    /// Forget the anonymous visitor and local conversation, then disconnect.
    /// Call before switching app accounts; configure again to create a new visitor.
    /// A storage failure is thrown so callers can retry before changing accounts.
    public func resetSession() throws {
        if let api, api.configuration.apiKey != nil {
            try storage.remove(key: api.installationStorageKey)
        }
        if let storageKey { try storage.remove(key: storageKey) }
        invalidate()
    }

    /// Refresh history and status. ChatView calls this automatically while active.
    public func refresh() async {
        guard !isLoading else { return }
        let version = generation
        isLoading = true
        defer { if generation == version { isLoading = false } }
        do {
            try await prepare(version: version)
            try await readPages(version: version)
            try check(version)
            lastError = nil
        } catch {
            handle(error, version: version)
        }
    }

    /// Send the current draft. Failed sends remain available for an explicit retry.
    public func send() {
        guard isReady, !isSending, pending == nil, let api else { return }
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.utf16.count <= 10_000 else {
            lastError = BarkyError.invalidMessage
            return
        }
        let value = PendingMessage(
            key: UUID().uuidString, body: body, createdAt: Date(),
            conversationID: conversationID,
            subject: conversationID == nil ? api.configuration.conversationSubject : nil,
            context: api.configuration.messageContext
        )
        do {
            // Durability before network I/O makes retries safe after termination.
            try persist(conversationID: conversationID, pending: value)
            pending = value
            draft = ""
            retryPendingMessage()
        } catch { lastError = error }
    }

    public func retryPendingMessage() {
        guard pending != nil, !isSending, isReady else { return }
        let version = generation
        isSending = true
        lastError = nil
        sending = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == version { self.isSending = false; self.sending = nil }
            }
            do {
                guard var value = self.pending, let api = self.api else { return }
                if value.messageID == nil {
                    let receipt = try await api.send(value)
                    try self.check(version)
                    guard UUID(uuidString: receipt.conversationId) != nil,
                          value.conversationID == nil || value.conversationID == receipt.conversationId
                    else { throw BarkyError.invalidResponse }
                    value.messageID = receipt.messageId
                    // Keep the original retry request until the acknowledgement is durable.
                    try self.persist(conversationID: receipt.conversationId, pending: value)
                    self.conversationID = receipt.conversationId
                    self.pending = value
                }
                // Polling owns cursor advancement; it may already be fetching a page.
                await self.refresh()
            } catch { self.handle(error, version: version) }
        }
    }

    private func prepare(version: UUID) async throws {
        guard let api else { throw BarkyError.notConfigured }
        let session = try await api.authenticate()
        try check(version)
        if storageKey == nil {
            let key = KeychainChatStorage.key(configuration: api.configuration, customerID: session.customerID)
            var state = try storage.load(key: key)
            if state.conversationID == nil && state.pending == nil {
                state.conversationID = session.conversationID
                try storage.save(state, key: key)
            }
            if let id = state.conversationID, UUID(uuidString: id) == nil { throw BarkyError.storageUnavailable }
            storageKey = key
            conversationID = state.conversationID
            pending = state.pending
        }
        isReady = true
    }

    private func readPages(version: UUID) async throws {
        guard let api, let conversationID else { return }
        // Drain pages in order. Internal-note gaps are legal; never infer cursor + 1.
        while true {
            let previousCursor = cursor
            let page = try await api.messages(conversationID: conversationID, after: previousCursor)
            try check(version)
            guard page.conversation.id == conversationID,
                  page.nextCursor >= previousCursor,
                  !page.hasMore || page.nextCursor > previousCursor,
                  page.messages.allSatisfy({ $0.position > previousCursor && $0.position <= page.nextCursor })
            else { throw BarkyError.invalidResponse }
            var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            for message in page.messages { byID[message.id] = message }
            messages = byID.values.sorted { $0.position < $1.position }
            conversationStatus = page.conversation.status
            if let id = pending?.messageID, messages.contains(where: { $0.id == id }) {
                try persist(conversationID: conversationID, pending: nil)
                pending = nil
            }
            cursor = page.nextCursor
            if !page.hasMore { return }
        }
    }

    private func persist(conversationID: String?, pending: PendingMessage?) throws {
        guard let storageKey else { throw BarkyError.storageUnavailable }
        try storage.save(StoredChat(conversationID: conversationID, pending: pending), key: storageKey)
    }

    private func check(_ version: UUID) throws {
        try Task.checkCancellation()
        guard generation == version else { throw CancellationError() }
    }

    private func handle(_ error: Error, version: UUID) {
        guard generation == version, !(error is CancellationError),
              (error as? URLError)?.code != .cancelled else { return }
        if error as? BarkyError == .identityChanged {
            invalidate()
            lastError = error
            return
        }
        lastError = error
    }

    func setVisible(_ visible: Bool, observer: UUID) {
        if visible { observers.insert(observer) } else { observers.remove(observer) }
        if observers.isEmpty { polling?.cancel(); polling = nil }
        else { restartPolling() }
    }

    private func restartPolling() {
        guard polling == nil, !observers.isEmpty else { return }
        polling = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                failures = self.lastError == nil ? 0 : min(failures + 1, 4)
                let interval = min((self.api?.configuration.pollingInterval ?? 3) * pow(2, Double(failures)), 60)
                do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
                catch { return }
            }
        }
    }
}

/// Configure with your SDK API key, then present ChatView().
@MainActor
public enum BarkySDK {
    public static let shared: BarkyClient = try! BarkyClient(storage: KeychainChatStorage())

    public static func configure(_ configuration: BarkyConfiguration, urlSessionConfiguration: URLSessionConfiguration? = nil) throws {
        try shared.configure(configuration, sessionConfiguration: urlSessionConfiguration)
    }

    public static func logout() { shared.invalidate() }

    public static func resetSession() throws { try shared.resetSession() }
}
