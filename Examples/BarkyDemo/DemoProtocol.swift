import Foundation

/// A synthetic transport used only by this example application, never by the SDK.
final class DemoProtocol: URLProtocol, @unchecked Sendable {
    static let customerID = UUID().uuidString
    private static let lock = NSLock()
    private static var messages: [[String: Any]] = []
    private static var receipts: [String: [String: String]] = [:]
    private static var failNext = false
    private static let conversationID = "00000000-0000-4000-8000-000000000001"

    static func failNextSend() { lock.lock(); failNext = true; lock.unlock() }

    // This protocol is installed only on the demo's SDK session. Intercept every
    // request so the example never contacts the hosted service, even with defaults.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let sessionRequest = request.url?.path.hasSuffix("sdk/sessions") == true
        if request.httpMethod == "POST" && !sessionRequest && Self.failNext {
            Self.failNext = false
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let result: [String: Any]
        if sessionRequest {
            result = ["token": "bk_session_local_demo", "customerId": Self.customerID,
                      "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))]
        } else if request.httpMethod == "POST" {
            let key = request.value(forHTTPHeaderField: "Idempotency-Key") ?? ""
            if let receipt = Self.receipts[key] { result = receipt }
            else {
                let payload = (try? JSONSerialization.jsonObject(with: body())) as? [String: Any]
                let id = UUID().uuidString
                Self.append(id: id, author: "customer", body: payload?["body"] as? String ?? "")
                let receipt = ["conversationId": Self.conversationID, "messageId": id]
                Self.receipts[key] = receipt
                result = receipt
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    Self.lock.lock(); defer { Self.lock.unlock() }
                    Self.append(id: UUID().uuidString, author: "operator", body: "Thanks for trying Barky! This is a local demo reply.")
                }
            }
        } else {
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value.flatMap(Int.init) ?? 0
            let messages = Self.messages.filter { ($0["position"] as? Int ?? 0) > cursor }
            result = ["conversation": ["id": Self.conversationID, "subject": "Demo", "status": "waiting"],
                      "messages": messages, "nextCursor": Self.messages.count, "hasMore": false]
        }
        let data = try! JSONSerialization.data(withJSONObject: result)
        let response = HTTPURLResponse(url: request.url!, statusCode: request.httpMethod == "POST" ? 201 : 200,
                                      httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func append(id: String, author: String, body: String) {
        messages.append(["id": id, "author": author, "body": body, "position": messages.count + 1,
                         "createdAt": ISO8601DateFormatter().string(from: Date())])
    }

    private func body() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            data.append(bytes, count: count)
        }
        return data
    }
}
