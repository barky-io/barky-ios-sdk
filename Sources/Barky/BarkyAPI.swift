import Foundation
import Security

// Reject redirects so bearer credentials cannot be forwarded to an unexpected host.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class BarkyAPI {
    let configuration: BarkyConfiguration
    private let session: URLSession
    private let storage: ChatStorage
    private var credential: BarkySession?
    private var credentialTask: Task<BarkySession, Error>?
    private var customerID: String?
    private var invalidated = false

    private struct Failure: Decodable {
        struct Detail: Decodable { let code: String }
        let error: Detail
    }

    init(configuration: BarkyConfiguration, session: URLSession? = nil, sessionConfiguration: URLSessionConfiguration? = nil, storage: ChatStorage? = nil) {
        self.configuration = configuration
        self.storage = storage ?? KeychainChatStorage()
        let settings = (sessionConfiguration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        settings.timeoutIntervalForRequest = 30
        settings.timeoutIntervalForResource = 60
        settings.urlCache = nil
        settings.httpCookieStorage = nil
        settings.httpShouldSetCookies = false
        settings.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = session ?? URLSession(configuration: settings, delegate: NoRedirects(), delegateQueue: nil)
    }

    func invalidate() {
        invalidated = true
        credentialTask?.cancel()
        credentialTask = nil
        credential = nil
        session.invalidateAndCancel()
    }

    func authenticate() async throws -> BarkySession {
        guard !invalidated else { throw CancellationError() }
        if let credential, credential.expiresAt.timeIntervalSinceNow > 30 { return credential }
        if let task = credentialTask { return try await task.value }
        let task = Task { @MainActor in
            defer { self.credentialTask = nil }
            return try await self.fetchCredential()
        }
        credentialTask = task
        return try await task.value
    }

    private func fetchCredential() async throws -> BarkySession {
        let value: BarkySession
        if let apiKey = configuration.apiKey {
            value = try await fetchAnonymousCredential(apiKey: apiKey)
        } else if let provider = configuration.sessionProvider {
            value = try await provider()
        } else {
            throw BarkyError.invalidConfiguration
        }
        try Task.checkCancellation()
        guard !invalidated else { throw CancellationError() }
        guard value.token.hasPrefix("bk_session_"), value.token.count <= 256,
              !value.token.contains(where: { $0.isWhitespace }),
              !value.customerID.isEmpty, value.expiresAt > Date(),
              value.conversationID.map({ UUID(uuidString: $0) != nil }) ?? true
        else { throw BarkyError.invalidSession }
        guard customerID == nil || customerID == value.customerID else {
            throw BarkyError.identityChanged
        }
        customerID = value.customerID
        credential = value
        return value
    }

    var installationStorageKey: String {
        KeychainChatStorage.key(configuration: configuration, customerID: "sdk-installation")
    }

    /// Restore or generate locally before any request. This public UUID is not
    /// the private installation credential or the server's internal customer ID.
    func localBarkyID(customerID: String? = nil) throws -> String {
        let key: String
        if configuration.apiKey != nil { key = installationStorageKey }
        else if let customerID { key = KeychainChatStorage.key(configuration: configuration, customerID: customerID) }
        else { throw BarkyError.invalidSession }
        var state = try storage.load(key: key)
        if let id = state.barkyID {
            guard UUID(uuidString: id) != nil else { throw BarkyError.storageUnavailable }
            return id
        }
        let id = UUID().uuidString.lowercased()
        state.barkyID = id
        try storage.save(state, key: key)
        return id
    }

    private func fetchAnonymousCredential(apiKey: String) async throws -> BarkySession {
        let barkyID = try localBarkyID()
        var state = try storage.load(key: installationStorageKey)
        if state.installationToken == nil {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw BarkyError.storageUnavailable
            }
            state.installationToken = "bk_install_" + Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            // Save before the first request so a lost response cannot lose the visitor.
            try storage.save(state, key: installationStorageKey)
        }
        guard let token = state.installationToken,
              token.range(of: "^bk_install_[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil
        else { throw BarkyError.storageUnavailable }
        var request = URLRequest(url: configuration.apiURL.appendingPathComponent("sdk/sessions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["installationToken": token, "barkyId": barkyID])
        var (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 400,
           (try? JSONDecoder().decode(Failure.self, from: data).error.code) == "invalid_request" {
            // Older Barky servers strictly reject the new optional field. Keep
            // chat usable during rolling upgrades; property sync can bind it later.
            try Task.checkCancellation()
            guard !invalidated else { throw CancellationError() }
            request.httpBody = try JSONEncoder().encode(["installationToken": token])
            (data, response) = try await session.data(for: request)
        }
        try Task.checkCancellation()
        guard !invalidated else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse else { throw BarkyError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let code = (try? JSONDecoder().decode(Failure.self, from: data).error.code) ?? "request_failed"
            throw BarkyError.http(status: response.statusCode, code: code)
        }
        return try JSONDecoder().decode(BarkySession.self, from: data)
    }

    func messages(conversationID: String, after: Int) async throws -> MessagePage {
        try await request(path: "conversations/\(conversationID)/messages", after: after)
    }

    func acknowledgeRead(conversationID: String, messageIDs: [String]) async throws {
        struct Payload: Codable { let messageIds: [String] }
        let response: Payload = try await request(
            path: "conversations/\(conversationID)/read-receipts",
            body: JSONEncoder().encode(Payload(messageIds: messageIDs))
        )
        guard Set(response.messageIds) == Set(messageIDs) else { throw BarkyError.invalidResponse }
    }

    func registerPushDevice(token: Data, environment: BarkyPushEnvironment, bundleID: String) async throws -> String {
        struct Payload: Encodable { let deviceToken: String; let environment: String; let bundleId: String }
        struct Receipt: Decodable { let registrationId: String }
        let result: Receipt = try await request(path: "push/devices", body: JSONEncoder().encode(Payload(
            deviceToken: token.map { String(format: "%02x", $0) }.joined(), environment: environment.rawValue, bundleId: bundleID)))
        guard UUID(uuidString: result.registrationId) != nil else { throw BarkyError.invalidResponse }
        return result.registrationId
    }

    func unregisterPushDevice(registrationID: String) async throws {
        struct Receipt: Decodable { let ok: Bool }
        let result: Receipt = try await request(path: "push/devices/unregister", body: JSONEncoder().encode(["registrationId": registrationID]))
        guard result.ok else { throw BarkyError.invalidResponse }
    }

    func unregisterPushBestEffort(registrationID: String, customerID: String) {
        guard let auth = credential, auth.customerID == customerID, auth.expiresAt > Date() else { return }
        var request = URLRequest(url: configuration.apiURL.appendingPathComponent("push/devices/unregister"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["registrationId": registrationID])
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 10
        settings.timeoutIntervalForResource = 15
        settings.urlCache = nil; settings.httpCookieStorage = nil
        let transport = URLSession(configuration: settings, delegate: NoRedirects(), delegateQueue: nil)
        transport.dataTask(with: request) { _, _, _ in transport.finishTasksAndInvalidate() }.resume()
    }

    func send(_ pending: PendingMessage) async throws -> MessageReceipt {
        struct Payload: Encodable {
            let body: String
            let context: [String: String]
            let subject: String?
        }
        let payload = Payload(body: pending.body, context: pending.context, subject: pending.subject)
        let path = pending.conversationID.map { "conversations/\($0)/messages" } ?? "conversations"
        return try await request(path: path, body: JSONEncoder().encode(payload), key: pending.key)
    }

    func updateProperties(_ update: PropertyUpdate) async throws -> String {
        struct Receipt: Decodable { let barkyId: String }
        let receipt: Receipt = try await request(path: "customer/properties", body: JSONEncoder().encode(update))
        return receipt.barkyId
    }

    private func request<T: Decodable>(path: String, after: Int? = nil, body: Data? = nil, key: String? = nil) async throws -> T {
        for attempt in 0...1 {
            let auth = try await authenticate()
            var components = URLComponents(url: configuration.apiURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            if let after { components.queryItems = [URLQueryItem(name: "after", value: String(after))] }
            var request = URLRequest(url: components.url!)
            request.httpMethod = body == nil ? "GET" : "POST"
            request.httpBody = body
            request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            if let key { request.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard !invalidated else { throw CancellationError() }
            guard let response = response as? HTTPURLResponse else { throw BarkyError.invalidResponse }
            if response.statusCode == 401 && attempt == 0 {
                // Do not discard a credential refreshed by another in-flight request.
                if credential?.token == auth.token { credential = nil }
                continue
            }
            guard (200..<300).contains(response.statusCode) else {
                let code = (try? JSONDecoder().decode(Failure.self, from: data).error.code) ?? "request_failed"
                throw BarkyError.http(status: response.statusCode, code: code)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                try WireDate.parse(decoder.singleValueContainer().decode(String.self))
            }
            do { return try decoder.decode(T.self, from: data) }
            catch { throw BarkyError.invalidResponse }
        }
        throw BarkyError.invalidSession
    }
}
