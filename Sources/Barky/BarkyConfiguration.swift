import Foundation

/// A short-lived customer credential issued by Barky.
/// Never put a Barky channel server key in an app.
public struct BarkySession: Decodable, Sendable {
    public let token: String
    public let customerID: String
    public let expiresAt: Date
    /// Optional server-restored conversation, for continuity on a new device.
    public let conversationID: String?

    public init(token: String, customerID: String, expiresAt: Date, conversationID: String? = nil) {
        self.token = token
        self.customerID = customerID
        self.expiresAt = expiresAt
        self.conversationID = conversationID
    }

    private enum CodingKeys: String, CodingKey {
        case token, customerID = "customerId", expiresAt, conversationID = "conversationId"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        token = try values.decode(String.self, forKey: .token)
        customerID = try values.decode(String.self, forKey: .customerID)
        expiresAt = try WireDate.parse(values.decode(String.self, forKey: .expiresAt))
        conversationID = try values.decodeIfPresent(String.self, forKey: .conversationID)
    }
}

public struct BarkyConfiguration: Sendable {
    /// The hosted Barky service used by default.
    public static let defaultAPIURL = URL(string: "https://app.barky.io/api/v1")!

    /// The complete API root. Override only for development or testing.
    public let apiURL: URL
    /// A stable channel/environment identifier used to isolate local conversation state.
    public let storageNamespace: String
    /// SDK API key for an iOS SDK channel. No customer backend is required.
    public let apiKey: String?
    public var pollingInterval: TimeInterval
    public var conversationSubject: String
    public var messageContext: [String: String]
    public let sessionProvider: (@Sendable () async throws -> BarkySession)?

    /// Connect directly to Barky as an anonymous visitor on this device.
    public init(
        apiURL: URL = BarkyConfiguration.defaultAPIURL,
        apiKey: String,
        pollingInterval: TimeInterval = 3,
        conversationSubject: String = "In-app support",
        messageContext: [String: String] = [:]
    ) {
        self.apiURL = apiURL
        self.apiKey = apiKey
        self.storageNamespace = apiKey
        self.pollingInterval = pollingInterval
        self.conversationSubject = conversationSubject
        self.messageContext = messageContext
        self.sessionProvider = nil
    }

    public init(
        apiURL: URL = BarkyConfiguration.defaultAPIURL,
        storageNamespace: String,
        pollingInterval: TimeInterval = 3,
        conversationSubject: String = "In-app support",
        messageContext: [String: String] = [:],
        sessionProvider: @escaping @Sendable () async throws -> BarkySession
    ) {
        self.apiURL = apiURL
        self.storageNamespace = storageNamespace
        self.apiKey = nil
        self.pollingInterval = pollingInterval
        self.conversationSubject = conversationSubject
        self.messageContext = messageContext
        self.sessionProvider = sessionProvider
    }

    func validate() throws {
        let local = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(apiURL.host?.lowercased() ?? "")
        guard apiURL.host != nil,
              apiURL.scheme == "https" || (apiURL.scheme == "http" && local),
              apiURL.user == nil, apiURL.password == nil,
              apiURL.query == nil, apiURL.fragment == nil,
              apiKey.map({ $0.range(of: "^bk_sdk_[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil }) ?? (sessionProvider != nil),
              !storageNamespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pollingInterval.isFinite, pollingInterval >= 1, pollingInterval <= 300,
              !conversationSubject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              conversationSubject.utf16.count <= 200,
              messageContext.keys.allSatisfy({ $0.utf16.count <= 100 })
        else { throw BarkyError.invalidConfiguration }
        let data = try JSONEncoder().encode(messageContext)
        guard String(decoding: data, as: UTF8.self).utf16.count <= 8192 else {
            throw BarkyError.invalidConfiguration
        }
    }
}

public enum BarkyError: Error, Equatable, Sendable {
    case notConfigured
    case invalidConfiguration
    case invalidSession
    case identityChanged
    case invalidMessage
    case invalidResponse
    case http(status: Int, code: String)
    case storageUnavailable
}

enum WireDate {
    static func parse(_ string: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: string) else { throw BarkyError.invalidResponse }
        return date
    }
}
