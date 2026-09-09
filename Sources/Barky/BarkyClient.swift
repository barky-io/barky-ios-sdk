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
    private var push: PushRegistrationController?
    private let storage: ChatStorage
    private var storageKey: String?
    private var cursor = 0
    private var generation = UUID()
    private var observers = Set<UUID>()
    private var polling: Task<Void, Never>?
    private var sending: Task<Void, Never>?
    private var reportingReads: Task<Void, Never>?
    private var visibleMessages: [UUID: Set<String>] = [:]
    private var visibleSince: [String: Date] = [:]
    private var acknowledgedReads = Set<String>()

    public convenience init(configuration: BarkyConfiguration, urlSessionConfiguration: URLSessionConfiguration? = nil) throws {
        try self.init(configuration: configuration, storage: KeychainChatStorage(), sessionConfiguration: urlSessionConfiguration)
    }

    init(configuration: BarkyConfiguration? = nil, storage: ChatStorage, session: URLSession? = nil,
         sessionConfiguration: URLSessionConfiguration? = nil) throws {
        self.storage = storage
        if let configuration {
            try configuration.validate()
            api = BarkyAPI(configuration: configuration, session: session, sessionConfiguration: sessionConfiguration, storage: storage)
            push = PushRegistrationController(api: api!, storage: storage)
        }
    }

    deinit { polling?.cancel(); sending?.cancel(); reportingReads?.cancel() }

    func configure(_ configuration: BarkyConfiguration, sessionConfiguration: URLSessionConfiguration? = nil) throws {
        try configuration.validate()
        invalidate()
        api = BarkyAPI(configuration: configuration, sessionConfiguration: sessionConfiguration, storage: storage)
        push = PushRegistrationController(api: api!, storage: storage)
        restartPolling()
    }

    /// Call on logout/account changes, before changing the session provider's user.
    /// Cancels work and clears visible data and credentials. It does not delete the
    /// customer's server conversation or the Keychain record needed for restoration.
    public func invalidate() {
        push?.disconnect(); push = nil
        generation = UUID()
        polling?.cancel(); polling = nil
        sending?.cancel(); sending = nil
        reportingReads?.cancel(); reportingReads = nil
        visibleMessages = [:]; visibleSince = [:]; acknowledgedReads = []
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

    /// Forward the fresh APNs token from your app delegate after obtaining consent.
    /// Throws on failure; call again with the latest token when connectivity returns.
    public func registerForPushNotifications(deviceToken: Data, environment: BarkyPushEnvironment,
                                             bundleID: String = Bundle.main.bundleIdentifier ?? "") async throws {
        guard let push else { throw BarkyError.notConfigured }
        try await push.register(token: deviceToken, environment: environment, bundleID: bundleID)
    }

    /// Await this before logout, changing accounts, or disabling support notifications.
    /// A failure means cleanup is unconfirmed; retry before changing the session provider.
    public func disablePushNotifications() async throws {
        guard let push else { throw BarkyError.notConfigured }
        try await push.disable()
    }

    /// Removes this device's push registration before resetting the visitor identity.
    public func resetSessionWithPushCleanup() async throws {
        try await disablePushNotifications()
        try resetSession()
    }

    /// Returns true only for a Barky notification authorized for the current customer.
    /// The host app presents ChatView after this returns true. Fetching does not mark read.
    public func handlePushNotification(_ userInfo: [AnyHashable: Any]) async throws -> Bool {
        guard let notification = BarkyPushNotification(userInfo: userInfo) else { return false }
        guard let api else { throw BarkyError.notConfigured }
        let version = generation
        let auth = try await api.authenticate()
        try check(version)
        guard auth.customerID.lowercased() == notification.customerID.lowercased() else { return false }
        do {
            let page = try await api.messages(conversationID: notification.conversationID, after: 0)
            try check(version)
            guard page.conversation.id.lowercased() == notification.conversationID.lowercased() else { throw BarkyError.invalidResponse }
        } catch BarkyError.http(status: 404, code: _) { return false }
        try await prepare(version: version)
        try check(version)
        if conversationID?.lowercased() != notification.conversationID.lowercased() {
            // Preserve an unsent draft or an uncertain send in another conversation.
            guard pending == nil, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BarkyError.pendingMessage }
            try persist(conversationID: notification.conversationID, pending: nil)
            generation = UUID()
            polling?.cancel(); polling = nil
            reportingReads?.cancel(); reportingReads = nil
            visibleMessages = [:]; visibleSince = [:]; acknowledgedReads = []
            conversationID = notification.conversationID
            conversationStatus = nil; messages = []; cursor = 0; isLoading = false
        }
        await refresh()
        restartPolling()
        return true
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
        if !visible { visibleMessages[observer] = nil }
        reconcileReadVisibility()
        if observers.isEmpty { polling?.cancel(); polling = nil }
        else { restartPolling() }
    }

    /// ChatView supplies only bubbles intersecting its unobscured viewport.
    /// Fetching messages or mounting a prefetched LazyVStack row is not a receipt.
    func setVisibleMessages(_ ids: Set<String>, observer: UUID) {
        guard observers.contains(observer) else { return }
        visibleMessages[observer] = ids
        reconcileReadVisibility()
    }

    private func reconcileReadVisibility() {
        let visible = observers.reduce(into: Set<String>()) { $0.formUnion(visibleMessages[$1] ?? []) }
        let eligible = Set(messages.filter { !$0.isFromCustomer && visible.contains($0.id) }.map(\.id))
            .subtracting(acknowledgedReads)
        visibleSince = visibleSince.filter { eligible.contains($0.key) }
        for id in eligible where visibleSince[id] == nil { visibleSince[id] = Date() }
        if visibleSince.isEmpty {
            reportingReads?.cancel(); reportingReads = nil
        } else if reportingReads == nil {
            startReportingReads()
        }
    }

    private func startReportingReads() {
        let version = generation
        reportingReads = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                // Require sustained visibility, and batch receipts while scrolling.
                let delay = failures == 0 ? 0.5 : min(3 * pow(2, Double(failures - 1)), 60)
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
                guard let self, self.generation == version,
                      let api = self.api, let conversationID = self.conversationID else { return }
                let ids = Array(self.visibleSince.filter { Date().timeIntervalSince($0.value) >= 0.5 }
                    .keys.sorted().prefix(100))
                if ids.isEmpty { continue }
                do {
                    try await api.acknowledgeRead(conversationID: conversationID, messageIDs: ids)
                    try self.check(version)
                    self.acknowledgedReads.formUnion(ids)
                    for id in ids { self.visibleSince[id] = nil }
                    failures = 0
                    if self.visibleSince.isEmpty { self.reportingReads = nil; return }
                } catch {
                    guard self.generation == version, !Task.isCancelled else { return }
                    if error as? BarkyError == .identityChanged {
                        self.invalidate()
                        return
                    }
                    // Receipt failures never block the composer. Retry while visible.
                    failures = min(failures + 1, 6)
                }
            }
        }
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

    public static func registerForPushNotifications(deviceToken: Data, environment: BarkyPushEnvironment,
                                                    bundleID: String = Bundle.main.bundleIdentifier ?? "") async throws {
        try await shared.registerForPushNotifications(deviceToken: deviceToken, environment: environment, bundleID: bundleID)
    }

    public static func disablePushNotifications() async throws { try await shared.disablePushNotifications() }
    public static func resetSessionWithPushCleanup() async throws { try await shared.resetSessionWithPushCleanup() }
    public static func handlePushNotification(_ userInfo: [AnyHashable: Any]) async throws -> Bool {
        try await shared.handlePushNotification(userInfo)
    }
}
