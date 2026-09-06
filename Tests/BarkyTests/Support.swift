import Foundation
import XCTest
@testable import Barky

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withValue<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (Int, String)
    static let handler = Locked<Handler?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let callback = Self.handler.withValue { $0! }
            let (status, body) = try callback(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func session(_ callback: @escaping Handler) -> URLSession {
        handler.withValue { $0 = callback }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@MainActor
final class MemoryStorage: ChatStorage {
    var values: [String: StoredChat] = [:]
    var failWrites = false
    func load(key: String) throws -> StoredChat { values[key] ?? StoredChat() }
    func save(_ state: StoredChat, key: String) throws {
        if failWrites { throw BarkyError.storageUnavailable }
        values[key] = state
    }
    func remove(key: String) throws { values[key] = nil }
}

let conversationID = "00000000-0000-4000-8000-000000000001"
let receipt = "{\"conversationId\":\"\(conversationID)\",\"messageId\":\"m1\"}"

func message(_ id: String, position: Int, author: String = "customer", body: String = "Hello") -> [String: Any] {
    ["id": id, "position": position, "author": author, "body": body, "createdAt": "2026-09-06T01:02:03.123Z"]
}

func page(_ messages: [[String: Any]], cursor: Int, hasMore: Bool = false) -> String {
    let object: [String: Any] = [
        "conversation": ["id": conversationID, "subject": "Support", "status": "waiting"],
        "messages": messages, "nextCursor": cursor, "hasMore": hasMore,
    ]
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

func session(customer: String = "customer-a", token: String = "bk_session_test", conversation: String? = nil) -> BarkySession {
    BarkySession(token: token, customerID: customer, expiresAt: Date().addingTimeInterval(3600), conversationID: conversation)
}

func configuration(provider: @escaping @Sendable () async throws -> BarkySession = { session() }) -> BarkyConfiguration {
    BarkyConfiguration(apiURL: URL(string: "https://barky.example/api/v1")!, storageNamespace: "channel-test", sessionProvider: provider)
}

@MainActor
func waitForSend(_ client: BarkyClient, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<400 {
        if !client.isSending { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("Send did not finish", file: file, line: line)
}

func requestBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return data
}
