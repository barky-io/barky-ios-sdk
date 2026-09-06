import Foundation

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
    private var credential: BarkySession?
    private var credentialTask: Task<BarkySession, Error>?
    private var customerID: String?
    private var invalidated = false

    private struct Failure: Decodable {
        struct Detail: Decodable { let code: String }
        let error: Detail
    }

    init(configuration: BarkyConfiguration, session: URLSession? = nil, sessionConfiguration: URLSessionConfiguration? = nil) {
        self.configuration = configuration
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
        let value = try await configuration.sessionProvider()
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

    func messages(conversationID: String, after: Int) async throws -> MessagePage {
        try await request(path: "conversations/\(conversationID)/messages", after: after)
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
