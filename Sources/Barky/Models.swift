import Foundation

public struct ChatMessage: Identifiable, Decodable, Equatable, Sendable {
    public let id: String
    /// "customer", "operator", or another server-defined author.
    public let author: String
    public let body: String
    public let position: Int
    public let createdAt: Date
    public var isFromCustomer: Bool { author == "customer" }
}

struct Conversation: Decodable, Sendable {
    let id: String
    let subject: String
    let status: String
}

struct MessagePage: Decodable, Sendable {
    let conversation: Conversation
    let messages: [ChatMessage]
    let nextCursor: Int
    let hasMore: Bool
}

struct MessageReceipt: Decodable, Sendable {
    let conversationId: String
    let messageId: String
}

struct PendingMessage: Codable, Equatable, Sendable {
    let key: String
    let body: String
    let createdAt: Date
    /// Immutable route and payload: a retry must replay the original request.
    let conversationID: String?
    let subject: String?
    let context: [String: String]
    var messageID: String?
}

struct StoredChat: Codable, Sendable {
    var conversationID: String?
    var pending: PendingMessage?
    var installationToken: String?
}
