import CoreGraphics
import XCTest
@testable import Barky

final class ReadReceiptTests: XCTestCase {
    private let replyID = "00000000-0000-4000-8000-000000000002"
    private let offscreenID = "00000000-0000-4000-8000-000000000003"

    @MainActor
    private func client(_ onRead: @escaping (URLRequest) throws -> (Int, String)) throws -> BarkyClient {
        let replyID = replyID, offscreenID = offscreenID
        let transport = StubURLProtocol.session { request in
            if request.url?.path.hasSuffix("read-receipts") == true { return try onRead(request) }
            let after = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? "0"
            let rows = after == "0" ? [message("customer-message", position: 1),
                message(replyID, position: 2, author: "operator"),
                message(offscreenID, position: 3, author: "operator")] : []
            return (200, page(rows, cursor: 3))
        }
        return try BarkyClient(configuration: configuration(provider: { session(conversation: conversationID) }),
                               storage: MemoryStorage(), session: transport)
    }

    private func acknowledgement(_ request: URLRequest) throws -> (Int, String) {
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer bk_session_test")
        XCTAssertNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
        return (200, String(decoding: requestBody(request), as: UTF8.self))
    }

    @MainActor
    private func waitFor(_ predicate: () -> Bool, timeout: Double = 3,
                         file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Receipt expectation timed out", file: file, line: line)
    }

    @MainActor
    func testOnlyDisplayedRepliesAreAcknowledgedAndReopeningDeduplicates() async throws {
        let requests = Locked<[URLRequest]>([])
        let client = try client { request in
            requests.withValue { $0.append(request) }
            return try self.acknowledgement(request)
        }
        defer { client.invalidate() }
        await client.refresh()
        let observer = UUID()
        client.setVisibleMessages([replyID], observer: observer)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(requests.withValue { $0.isEmpty }, "Fetching or a hidden chat never marks read")
        client.setVisible(true, observer: observer)
        client.setVisibleMessages([replyID, "customer-message", "unknown"], observer: observer)
        await waitFor { requests.withValue { $0.count == 1 } }
        let payload = try JSONSerialization.jsonObject(with: requestBody(requests.withValue { $0[0] })) as! [String: [String]]
        XCTAssertEqual(payload["messageIds"], [replyID])
        try await Task.sleep(nanoseconds: 100_000_000)
        client.setVisible(false, observer: observer)
        client.setVisible(true, observer: observer)
        client.setVisibleMessages([replyID], observer: observer)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(requests.withValue { $0.count }, 1)
        XCTAssertNil(client.lastError)
    }

    @MainActor
    func testScrollingAwayAndBackgroundingCancelUnconfirmedVisibility() async throws {
        let count = Locked(0)
        let client = try client { request in
            count.withValue { $0 += 1 }
            return try self.acknowledgement(request)
        }
        defer { client.invalidate() }
        await client.refresh()
        let observer = UUID()
        client.setVisible(true, observer: observer)
        client.setVisibleMessages([replyID], observer: observer)
        client.setVisibleMessages([], observer: observer)
        try await Task.sleep(nanoseconds: 650_000_000)
        XCTAssertEqual(count.withValue { $0 }, 0)
        client.setVisibleMessages([replyID], observer: observer)
        client.setVisible(false, observer: observer)
        try await Task.sleep(nanoseconds: 650_000_000)
        XCTAssertEqual(count.withValue { $0 }, 0)
        client.setVisible(true, observer: observer)
        client.setVisibleMessages([replyID], observer: observer)
        await waitFor { count.withValue { $0 == 1 } }
    }

    @MainActor
    func testReceiptFailureRetriesWithoutBlockingChat() async throws {
        let bodies = Locked<[Data]>([])
        let client = try client { request in
            let attempt = bodies.withValue { $0.append(requestBody(request)); return $0.count }
            if attempt == 1 { throw URLError(.networkConnectionLost) }
            return try self.acknowledgement(request)
        }
        defer { client.invalidate() }
        await client.refresh()
        let observer = UUID()
        client.setVisible(true, observer: observer)
        client.setVisibleMessages([replyID], observer: observer)
        await waitFor({ bodies.withValue { $0.count >= 2 } }, timeout: 6)
        XCTAssertEqual(bodies.withValue { $0[0] }, bodies.withValue { $0[1] })
        XCTAssertTrue(client.isReady)
        XCTAssertNil(client.lastError)
    }

    @MainActor
    func testIdentityResetCancelsQueuedReceipts() async throws {
        let count = Locked(0)
        let client = try client { request in
            count.withValue { $0 += 1 }
            return try self.acknowledgement(request)
        }
        await client.refresh()
        let observer = UUID()
        client.setVisible(true, observer: observer)
        client.setVisibleMessages([replyID], observer: observer)
        client.invalidate()
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(count.withValue { $0 }, 0)
        XCTAssertTrue(client.messages.isEmpty)
    }

    func testViewportExcludesPrefetchedAndObscuredRows() {
        let viewport = CGRect(x: 0, y: 0, width: 300, height: 400)
        XCTAssertTrue(MessageVisibility.isReadable(CGRect(x: 20, y: 100, width: 240, height: 80), in: viewport))
        XCTAssertFalse(MessageVisibility.isReadable(CGRect(x: 20, y: 410, width: 240, height: 80), in: viewport))
        XCTAssertFalse(MessageVisibility.isReadable(CGRect(x: 20, y: -70, width: 240, height: 80), in: viewport))
        XCTAssertFalse(MessageVisibility.isReadable(CGRect(x: 20, y: 380, width: 240, height: 80), in: viewport))
        XCTAssertTrue(MessageVisibility.isReadable(CGRect(x: 20, y: -200, width: 240, height: 1000), in: viewport))
        XCTAssertFalse(MessageVisibility.isReadable(CGRect.zero, in: viewport))
        XCTAssertFalse(MessageVisibility.isReadable(viewport, in: .zero))
    }
}
