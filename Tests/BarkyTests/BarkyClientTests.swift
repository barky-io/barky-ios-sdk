import XCTest
@testable import Barky

final class BarkyClientTests: XCTestCase {
    @MainActor
    func testFirstMessageCreatesConversationAndFetchesReply() async throws {
        let storage = MemoryStorage()
        let requests = Locked<[URLRequest]>([])
        let urlSession = StubURLProtocol.session { request in
            requests.withValue { $0.append(request) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer bk_session_test")
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url?.path, "/api/v1/conversations")
                XCTAssertNotNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
                XCTAssertEqual(body["body"] as? String, "Hello")
                XCTAssertEqual(body["subject"] as? String, "In-app support")
                return (201, receipt)
            }
            return (200, page([message("m1", position: 1), message("m2", position: 3, author: "operator", body: "How can we help?")], cursor: 3))
        }
        let client = try BarkyClient(configuration: configuration(), storage: storage, session: urlSession)
        await client.refresh()
        XCTAssertTrue(client.isReady)
        XCTAssertTrue(requests.withValue { $0.isEmpty }, "Opening an empty chat must not create a conversation")
        client.draft = "  Hello  "
        client.send()
        await waitForSend(client)
        XCTAssertNil(client.lastError)
        XCTAssertEqual(client.conversationID, conversationID)
        XCTAssertEqual(client.messages.map(\.body), ["Hello", "How can we help?"])
        XCTAssertNil(client.pending)
        XCTAssertEqual(client.draft, "")
        XCTAssertEqual(storage.values.values.first?.conversationID, conversationID)
    }

    @MainActor
    func testLostResponseReplaysIdenticalCreateAcrossClientRestart() async throws {
        let storage = MemoryStorage()
        let posts = Locked<[(String, Data)]>([])
        let firstTransport = StubURLProtocol.session { request in
            posts.withValue { $0.append((request.value(forHTTPHeaderField: "Idempotency-Key")!, requestBody(request))) }
            throw URLError(.networkConnectionLost)
        }
        let first = try BarkyClient(configuration: configuration(), storage: storage, session: firstTransport)
        await first.refresh()
        first.draft = "Hello"
        first.send()
        await waitForSend(first)
        XCTAssertNotNil(first.pending)
        XCTAssertNotNil(first.lastError)
        first.invalidate()

        let retryTransport = StubURLProtocol.session { request in
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url?.path, "/api/v1/conversations")
                posts.withValue { $0.append((request.value(forHTTPHeaderField: "Idempotency-Key")!, requestBody(request))) }
                return (201, receipt)
            }
            return (200, page([message("m1", position: 1)], cursor: 1))
        }
        let restored = try BarkyClient(configuration: configuration(), storage: storage, session: retryTransport)
        await restored.refresh()
        XCTAssertEqual(restored.pending?.body, "Hello")
        restored.retryPendingMessage()
        await waitForSend(restored)
        let attempts = posts.withValue { $0 }
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0].0, attempts[1].0)
        // JSON key ordering is irrelevant; the logical request must be identical.
        XCTAssertEqual(try JSONSerialization.jsonObject(with: attempts[0].1) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: attempts[1].1) as? NSDictionary)
        XCTAssertEqual(restored.messages.count, 1)
        XCTAssertNil(restored.pending)
    }

    @MainActor
    func testRestorePaginatesThroughPositionGapsAndPollsFromCursor() async throws {
        let cursors = Locked<[Int]>([])
        let transport = StubURLProtocol.session { request in
            let after = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems![0].value!)!
            cursors.withValue { $0.append(after) }
            switch after {
            case 0: return (200, page([message("m1", position: 1)], cursor: 1, hasMore: true))
            case 1: return (200, page([message("m2", position: 4, author: "operator")], cursor: 4))
            default: return (200, page([], cursor: 4))
            }
        }
        let client = try BarkyClient(configuration: configuration { session(conversation: conversationID) },
                                     storage: MemoryStorage(), session: transport)
        await client.refresh()
        await client.refresh()
        XCTAssertNil(client.lastError)
        XCTAssertEqual(client.messages.map(\.position), [1, 4])
        XCTAssertEqual(cursors.withValue { $0 }, [0, 1, 4])
    }

    @MainActor
    func testAppendOmitsSubjectAndUsesNewKeyForEachIntentionalMessage() async throws {
        let keys = Locked<[String]>([])
        let transport = StubURLProtocol.session { request in
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url?.path, "/api/v1/conversations/\(conversationID)/messages")
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
                XCTAssertNil(body["subject"])
                let count = keys.withValue { keys in
                    keys.append(request.value(forHTTPHeaderField: "Idempotency-Key")!); return keys.count
                }
                return (201, "{\"conversationId\":\"\(conversationID)\",\"messageId\":\"m\(count)\"}")
            }
            let count = keys.withValue { $0.count }
            let after = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems![0].value!)!
            return (200, page(count > after ? [message("m\(count)", position: count)] : [], cursor: count))
        }
        let client = try BarkyClient(configuration: configuration { session(conversation: conversationID) },
                                     storage: MemoryStorage(), session: transport)
        await client.refresh()
        for _ in 0..<2 { client.draft = "Hello"; client.send(); await waitForSend(client) }
        XCTAssertEqual(client.messages.count, 2)
        XCTAssertEqual(Set(keys.withValue { $0 }).count, 2)
    }

    @MainActor
    func test401RefreshesSessionOnceAndKeepsRetryKey() async throws {
        let issued = Locked(0)
        let keys = Locked<[String]>([])
        let config = configuration {
            let count = issued.withValue { $0 += 1; return $0 }
            return session(token: "bk_session_\(count)")
        }
        let transport = StubURLProtocol.session { request in
            if request.httpMethod == "POST" {
                keys.withValue { $0.append(request.value(forHTTPHeaderField: "Idempotency-Key")!) }
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer bk_session_1" {
                    return (401, "{\"error\":{\"code\":\"unauthenticated\"}}")
                }
                return (201, receipt)
            }
            return (200, page([message("m1", position: 1)], cursor: 1))
        }
        let client = try BarkyClient(configuration: config, storage: MemoryStorage(), session: transport)
        await client.refresh()
        client.draft = "Hello"; client.send(); await waitForSend(client)
        XCTAssertEqual(issued.withValue { $0 }, 2)
        XCTAssertEqual(Set(keys.withValue { $0 }).count, 1)
        XCTAssertEqual(client.messages.count, 1)
    }

    @MainActor
    func testChangedIdentityOnRefreshClearsConversationAndStops() async throws {
        let issued = Locked(0)
        let config = configuration {
            let count = issued.withValue { $0 += 1; return $0 }
            return session(customer: count == 1 ? "a" : "b", conversation: conversationID)
        }
        let requests = Locked(0)
        let transport = StubURLProtocol.session { _ in
            let count = requests.withValue { $0 += 1; return $0 }
            return count == 1 ? (200, page([message("m1", position: 1)], cursor: 1)) : (401, "{}")
        }
        let client = try BarkyClient(configuration: config, storage: MemoryStorage(), session: transport)
        await client.refresh()
        XCTAssertEqual(client.messages.count, 1)
        client.draft = "private draft"
        await client.refresh()
        XCTAssertEqual(client.lastError as? BarkyError, .identityChanged)
        XCTAssertTrue(client.messages.isEmpty)
        XCTAssertTrue(client.draft.isEmpty)
        XCTAssertFalse(client.isReady)
        XCTAssertEqual(requests.withValue { $0 }, 2, "Must never use the new customer's token on the old conversation")
    }

    @MainActor
    func testStorageFailurePreventsNetworkMutationAndRetainsDraft() async throws {
        let storage = MemoryStorage()
        let transport = StubURLProtocol.session { _ in XCTFail("Must not send without durable retry state"); return (500, "{}") }
        let client = try BarkyClient(configuration: configuration(), storage: storage, session: transport)
        await client.refresh()
        storage.failWrites = true
        client.draft = "Hello"; client.send()
        XCTAssertEqual(client.draft, "Hello")
        XCTAssertEqual(client.lastError as? BarkyError, .storageUnavailable)
        XCTAssertFalse(client.isSending)
    }

    @MainActor
    func testNonAdvancingPaginationFailsInsteadOfLooping() async throws {
        let transport = StubURLProtocol.session { _ in (200, page([], cursor: 0, hasMore: true)) }
        let client = try BarkyClient(configuration: configuration { session(conversation: conversationID) },
                                     storage: MemoryStorage(), session: transport)
        await client.refresh()
        XCTAssertEqual(client.lastError as? BarkyError, .invalidResponse)
    }

    @MainActor
    func testLocalRecordsAreIsolatedByCustomerChannelAndServer() throws {
        let first = configuration()
        let second = BarkyConfiguration(apiURL: first.apiURL, storageNamespace: "another-channel") { session() }
        let third = BarkyConfiguration(apiURL: URL(string: "https://other.example/api/v1")!, storageNamespace: first.storageNamespace) { session() }
        let keys = [KeychainChatStorage.key(configuration: first, customerID: "a"),
                    KeychainChatStorage.key(configuration: first, customerID: "b"),
                    KeychainChatStorage.key(configuration: second, customerID: "a"),
                    KeychainChatStorage.key(configuration: third, customerID: "a")]
        XCTAssertEqual(Set(keys).count, 4)
    }

    @MainActor
    func testValidationUsesServerUTF16LengthAndRejectsChannelKey() async throws {
        let client = try BarkyClient(configuration: configuration(), storage: MemoryStorage())
        await client.refresh()
        client.draft = String(repeating: "😀", count: 5_001)
        client.send()
        XCTAssertEqual(client.lastError as? BarkyError, .invalidMessage)
        XCTAssertNil(client.pending)

        let invalid = try BarkyClient(configuration: configuration { session(token: "bk_channel_secret") }, storage: MemoryStorage())
        await invalid.refresh()
        XCTAssertEqual(invalid.lastError as? BarkyError, .invalidSession)
        XCTAssertFalse(invalid.isReady)
    }

    @MainActor
    func testConcurrentAuthenticationValidatesEveryWaiter() async throws {
        let count = Locked(0)
        let api = BarkyAPI(configuration: configuration {
            count.withValue { $0 += 1 }
            try await Task.sleep(nanoseconds: 20_000_000)
            return session(token: "not-a-session")
        })
        let a = Task { try await api.authenticate() }
        let b = Task { try await api.authenticate() }
        for task in [a, b] {
            do { _ = try await task.value; XCTFail("Invalid credentials must never escape validation") }
            catch { XCTAssertEqual(error as? BarkyError, .invalidSession) }
        }
        XCTAssertEqual(count.withValue { $0 }, 1)
    }

    @MainActor
    func testLogoutWhileProviderIsSuspendedCannotRestorePrivateState() async throws {
        let started = Locked(false)
        let client = try BarkyClient(configuration: configuration {
            started.withValue { $0 = true }
            try? await Task.sleep(nanoseconds: 50_000_000)
            return session(conversation: conversationID)
        }, storage: MemoryStorage())
        let refresh = Task { await client.refresh() }
        while !started.withValue({ $0 }) { await Task.yield() }
        client.invalidate()
        await refresh.value
        XCTAssertFalse(client.isReady)
        XCTAssertNil(client.conversationID)
        XCTAssertTrue(client.messages.isEmpty)
    }

    func testSessionDecodesServerDatesWithAndWithoutFractionalSeconds() throws {
        for date in ["2026-09-06T01:02:03.123Z", "2026-09-06T01:02:03Z"] {
            let data = Data("{\"token\":\"bk_session_test\",\"customerId\":\"a\",\"expiresAt\":\"\(date)\"}".utf8)
            let decoded = try JSONDecoder().decode(BarkySession.self, from: data)
            XCTAssertEqual(decoded.customerID, "a")
        }
    }

    func testConfigurationRequiresHTTPSExceptLoopback() throws {
        for endpoint in ["http://example.com/api/v1", "https://user:password@example.com/api/v1", "https://example.com/api/v1?token=x"] {
            let value = BarkyConfiguration(apiURL: URL(string: endpoint)!, storageNamespace: "test") { session() }
            XCTAssertThrowsError(try value.validate())
        }
        let local = BarkyConfiguration(apiURL: URL(string: "http://127.0.0.1:3000/api/v1")!, storageNamespace: "test") { session() }
        XCTAssertNoThrow(try local.validate())
    }

    @MainActor
    func testAcknowledgedSendSurvivesHistoryFailureWithoutSecondPost() async throws {
        let storage = MemoryStorage()
        let postCount = Locked(0)
        let transport = StubURLProtocol.session { request in
            if request.httpMethod == "POST" {
                postCount.withValue { $0 += 1 }
                return (201, receipt)
            }
            throw URLError(.notConnectedToInternet)
        }
        let client = try BarkyClient(configuration: configuration(), storage: storage, session: transport)
        await client.refresh()
        client.draft = "Hello"; client.send(); await waitForSend(client)
        XCTAssertEqual(client.pending?.messageID, "m1")
        XCTAssertEqual(client.conversationID, conversationID)
        client.invalidate()
        let restoredTransport = StubURLProtocol.session { request in
            XCTAssertEqual(request.httpMethod, "GET", "An acknowledged send must never be resent")
            return (200, page([message("m1", position: 1)], cursor: 1))
        }
        let restored = try BarkyClient(configuration: configuration(), storage: storage, session: restoredTransport)
        await restored.refresh()
        XCTAssertEqual(restored.messages.count, 1)
        XCTAssertNil(restored.pending)
        XCTAssertEqual(postCount.withValue { $0 }, 1)
    }

    @MainActor
    func testRepeatedUnauthorizedResponseDoesNotLoop() async throws {
        let requestCount = Locked(0)
        let providerCount = Locked(0)
        let transport = StubURLProtocol.session { _ in
            requestCount.withValue { $0 += 1 }
            return (401, "{\"error\":{\"code\":\"unauthenticated\"}}")
        }
        let client = try BarkyClient(configuration: configuration {
            providerCount.withValue { $0 += 1 }
            return session(conversation: conversationID)
        }, storage: MemoryStorage(), session: transport)
        await client.refresh()
        XCTAssertEqual(requestCount.withValue { $0 }, 2)
        XCTAssertEqual(providerCount.withValue { $0 }, 2)
        XCTAssertEqual(client.lastError as? BarkyError, .http(status: 401, code: "unauthenticated"))
    }
}
