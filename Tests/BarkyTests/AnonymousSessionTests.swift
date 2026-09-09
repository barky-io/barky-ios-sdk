import XCTest
@testable import Barky

final class AnonymousSessionTests: XCTestCase {
    private let apiKey = "bk_sdk_" + String(repeating: "a", count: 43)

    @MainActor
    func testOlderServerBootstrapFallbackKeepsLocalIDAndPrivateCredential() async throws {
        let storage = MemoryStorage()
        let bodies = Locked<[[String: String]]>([])
        let api = BarkyAPI(configuration: BarkyConfiguration(apiKey: apiKey, propertyCollection: .disabled), session: StubURLProtocol.session { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: String]
            bodies.withValue { $0.append(body) }
            if body["barkyId"] != nil { return (400, "{\"error\":{\"code\":\"invalid_request\"}}") }
            return (201, "{\"token\":\"bk_session_test\",\"customerId\":\"visitor\",\"expiresAt\":\"2099-01-01T00:00:00Z\"}")
        }, storage: storage)
        let id = try api.localBarkyID()
        let authenticated = try await api.authenticate()
        XCTAssertEqual(authenticated.customerID, "visitor")
        let sent = bodies.withValue { $0 }
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0]["barkyId"], id)
        XCTAssertNil(sent[1]["barkyId"])
        XCTAssertEqual(sent[0]["installationToken"], sent[1]["installationToken"])
        XCTAssertEqual(try api.localBarkyID(), id)
        api.invalidate()
    }

    @MainActor
    func testAPIKeyOnlyConfigurationBootstrapsAndSendsToBarky() async throws {
        let config = BarkyConfiguration(apiKey: apiKey, propertyCollection: .disabled)
        try config.validate()
        let requests = Locked<[String]>([])
        let transport = StubURLProtocol.session { request in
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "app.barky.io")
            let path = try XCTUnwrap(request.url?.path)
            requests.withValue { $0.append(path) }
            if path == "/api/v1/sdk/sessions" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(self.apiKey)")
                return (201, "{\"token\":\"bk_session_test\",\"customerId\":\"visitor\",\"expiresAt\":\"2099-01-01T00:00:00Z\"}")
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer bk_session_test")
            return (201, receipt)
        }
        let api = BarkyAPI(configuration: config, session: transport, storage: MemoryStorage())
        defer { api.invalidate() }
        let result = try await api.send(PendingMessage(key: UUID().uuidString, body: "Hello", createdAt: Date(), conversationID: nil, subject: "Support", context: [:]))
        XCTAssertEqual(result.conversationId, conversationID)
        XCTAssertEqual(requests.withValue { $0 }, ["/api/v1/sdk/sessions", "/api/v1/conversations"])

        let verified = BarkyConfiguration(storageNamespace: "verified-test") { session() }
        try verified.validate()
        XCTAssertEqual(verified.apiURL, config.apiURL)
    }

    @MainActor
    func testDirectBootstrapRestoresInstallationAndResetCreatesNewVisitor() async throws {
        let storage = MemoryStorage()
        let tokens = Locked<[String]>([])
        let config = BarkyConfiguration(apiURL: URL(string: "https://barky.example/api/v1")!, apiKey: apiKey, propertyCollection: .disabled)
        func transport() -> URLSession {
            StubURLProtocol.session { request in
                XCTAssertEqual(request.url?.path, "/api/v1/sdk/sessions")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(self.apiKey)")
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: String]
                XCTAssertEqual(Set(body.keys), ["installationToken", "barkyId"])
                XCTAssertNotNil(UUID(uuidString: body["barkyId"] ?? ""))
                let token = try XCTUnwrap(body["installationToken"])
                XCTAssertNotNil(token.range(of: "^bk_install_[A-Za-z0-9_-]{43}$", options: .regularExpression))
                tokens.withValue { $0.append(token) }
                return (201, "{\"token\":\"bk_session_test\",\"customerId\":\"visitor\",\"expiresAt\":\"2099-01-01T00:00:00Z\"}")
            }
        }
        let first = try BarkyClient(configuration: config, storage: storage, session: transport())
        await first.refresh()
        XCTAssertTrue(first.isReady)
        first.invalidate()
        let restored = try BarkyClient(configuration: config, storage: storage, session: transport())
        await restored.refresh()
        XCTAssertTrue(restored.isReady)
        XCTAssertEqual(tokens.withValue { $0[0] }, tokens.withValue { $0[1] })
        try restored.resetSession()
        XCTAssertFalse(restored.isReady)
        let fresh = try BarkyClient(configuration: config, storage: storage, session: transport())
        await fresh.refresh()
        XCTAssertNotEqual(tokens.withValue { $0[0] }, tokens.withValue { $0[2] })
    }

    @MainActor
    func testBootstrapPersistsBeforeNetworkAndLostResponseUsesSameSecret() async throws {
        let storage = MemoryStorage()
        let tokens = Locked<[String]>([])
        let config = BarkyConfiguration(apiURL: URL(string: "https://barky.example/api/v1")!, apiKey: apiKey, propertyCollection: .disabled)
        let transport = StubURLProtocol.session { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: String]
            tokens.withValue { $0.append(body["installationToken"]!) }
            throw URLError(.networkConnectionLost)
        }
        let client = try BarkyClient(configuration: config, storage: storage, session: transport)
        storage.failWrites = true
        await client.refresh()
        XCTAssertTrue(tokens.withValue { $0.isEmpty })
        XCTAssertEqual(client.lastError as? BarkyError, .storageUnavailable)
        storage.failWrites = false
        await client.refresh()
        await client.refresh()
        XCTAssertEqual(tokens.withValue { $0.count }, 2)
        XCTAssertEqual(tokens.withValue { $0[0] }, tokens.withValue { $0[1] })
    }

    @MainActor
    func testRefreshAfter401KeepsInstallationAndDoesNotAcceptChannelKey() async throws {
        let storage = MemoryStorage()
        let installations = Locked<[String]>([])
        let config = BarkyConfiguration(apiURL: URL(string: "https://barky.example/api/v1")!, apiKey: apiKey, propertyCollection: .disabled)
        let transport = StubURLProtocol.session { request in
            if request.url?.path.hasSuffix("sdk/sessions") == true {
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: String]
                let count = installations.withValue { values in values.append(body["installationToken"]!); return values.count }
                return (201, "{\"token\":\"bk_session_\(count)\",\"customerId\":\"visitor\",\"expiresAt\":\"2099-01-01T00:00:00Z\"}")
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer bk_session_1" {
                return (401, "{\"error\":{\"code\":\"expired\"}}")
            }
            return (201, receipt)
        }
        let api = BarkyAPI(configuration: config, session: transport, storage: storage)
        _ = try await api.send(PendingMessage(key: "retry", body: "Hello", createdAt: Date(), conversationID: nil, subject: "Support", context: [:]))
        XCTAssertEqual(installations.withValue { $0.count }, 2)
        XCTAssertEqual(installations.withValue { $0[0] }, installations.withValue { $0[1] })
        XCTAssertThrowsError(try BarkyClient(configuration: BarkyConfiguration(apiURL: config.apiURL, apiKey: "bk_channel_secret"), storage: storage))
    }
}
