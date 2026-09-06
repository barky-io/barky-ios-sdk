import XCTest
@testable import Barky

final class LiveIntegrationTests: XCTestCase {
    /// Runs only with a maintainer-provided disposable localhost backend fixture.
    @MainActor
    func testRealBarkyHTTPRoundTripAndRestoration() async throws {
        guard let raw = ProcessInfo.processInfo.environment["BARKY_INTEGRATION_URL"],
              let base = URL(string: raw), base.host == "127.0.0.1" else {
            throw XCTSkip("Set BARKY_INTEGRATION_URL to the isolated local fixture server")
        }
        let config = BarkyConfiguration(apiURL: base.appendingPathComponent("api/v1"), storageNamespace: "integration") {
            let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent("session"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BarkyError.invalidSession }
            return try JSONDecoder().decode(BarkySession.self, from: data)
        }
        let storage = MemoryStorage()
        let client = try BarkyClient(configuration: config, storage: storage)
        await client.refresh()
        XCTAssertTrue(client.isReady)
        client.draft = "Hello from the real Swift SDK 😀"
        client.send(); await waitForSend(client)
        XCTAssertNil(client.lastError)
        let id = try XCTUnwrap(client.conversationID)
        XCTAssertEqual(client.messages.count, 1)

        var request = URLRequest(url: base.appendingPathComponent("test/reply"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["conversationId": id])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        await client.refresh()
        XCTAssertEqual(client.messages.map(\.body), ["Hello from the real Swift SDK 😀", "A real operator reply"])
        XCTAssertEqual(client.conversationStatus, "waiting")
        client.invalidate()

        let restored = try BarkyClient(configuration: config, storage: storage)
        await restored.refresh()
        XCTAssertEqual(restored.conversationID, id)
        XCTAssertEqual(restored.messages.count, 2)
        restored.draft = "Thank you!"; restored.send(); await waitForSend(restored)
        XCTAssertNil(restored.lastError)
        XCTAssertEqual(restored.messages.map(\.position), [1, 2, 4], "The internal note occupies position 3 and must never appear")
        XCTAssertEqual(restored.conversationStatus, "open")
    }
}
