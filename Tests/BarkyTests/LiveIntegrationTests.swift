import XCTest
@testable import Barky

final class LiveIntegrationTests: XCTestCase {
    @MainActor
    func testDirectSDKKeyRoundTripRestorationAndReset() async throws {
        guard let raw = ProcessInfo.processInfo.environment["BARKY_INTEGRATION_URL"],
              let base = URL(string: raw), base.host == "127.0.0.1" else {
            throw XCTSkip("Set BARKY_INTEGRATION_URL to the isolated local fixture server")
        }
        let (keyData, _) = try await URLSession.shared.data(from: base.appendingPathComponent("sdk-key"))
        let key = try JSONDecoder().decode([String: String].self, from: keyData)["apiKey"]!
        let config = BarkyConfiguration(apiURL: base.appendingPathComponent("api/v1"), apiKey: key)
        let storage = MemoryStorage()
        let client = try BarkyClient(configuration: config, storage: storage)
        let localID = try XCTUnwrap(client.barkyID)
        await client.refresh()
        XCTAssertTrue(client.isReady)
        client.draft = "Hello directly from the SDK"; client.send(); await waitForSend(client)
        XCTAssertNil(client.lastError)
        let id = try XCTUnwrap(client.conversationID)
        try await client.setUserProperties(["plan": "pro", "obsolete": true])
        try await client.setUserProperties(["obsolete": .null])
        try await client.setDeviceProperties(["appearance": "dark"])
        let profileURL = base.appendingPathComponent("test/profile").appending(queryItems: [URLQueryItem(name: "conversationId", value: id)])
        let (profileData, profileResponse) = try await URLSession.shared.data(from: profileURL)
        XCTAssertEqual((profileResponse as? HTTPURLResponse)?.statusCode, 200)
        let profile = try JSONSerialization.jsonObject(with: profileData) as! [String: Any]
        XCTAssertEqual(profile["barkyId"] as? String, localID)
        XCTAssertEqual(profile["userProperties"] as? [String: String], ["plan": "pro"])
        let device = (profile["devices"] as! [[String: Any]])[0]
        XCTAssertEqual(device["deviceProperties"] as? [String: String], ["appearance": "dark"])
        XCTAssertNotNil((device["systemProperties"] as! [String: Any])["os_version"])
        var reply = URLRequest(url: base.appendingPathComponent("test/reply"))
        reply.httpMethod = "POST"
        reply.setValue("application/json", forHTTPHeaderField: "Content-Type")
        reply.httpBody = try JSONSerialization.data(withJSONObject: ["conversationId": id])
        let (_, response) = try await URLSession.shared.data(for: reply)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        client.invalidate()
        let restored = try BarkyClient(configuration: config, storage: storage)
        XCTAssertEqual(restored.barkyID, localID)
        await restored.refresh()
        XCTAssertNil(restored.lastError)
        XCTAssertEqual(restored.conversationID, id)
        XCTAssertEqual(restored.messages.map(\.body), ["Hello directly from the SDK", "A real operator reply"])
        try restored.resetSession()
        let next = try BarkyClient(configuration: config, storage: storage)
        XCTAssertNotEqual(next.barkyID, localID)
        await next.refresh()
        XCTAssertTrue(next.isReady)
        XCTAssertNil(next.conversationID)
        XCTAssertTrue(next.messages.isEmpty)
    }

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
