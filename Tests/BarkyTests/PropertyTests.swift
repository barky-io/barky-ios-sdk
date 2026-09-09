import Foundation
import XCTest
@testable import Barky

@MainActor
final class PropertyTests: XCTestCase {
    func testLocalBarkyIDExistsOfflineRestoresAndRotatesOnlyOnReset() throws {
        let config = BarkyConfiguration(apiKey: "bk_sdk_" + String(repeating: "p", count: 43), propertyCollection: .disabled)
        let storage = MemoryStorage()
        let first = try BarkyClient(configuration: config, storage: storage)
        let original = try XCTUnwrap(first.barkyID)
        XCTAssertNotNil(UUID(uuidString: original))
        XCTAssertNil(storage.values.values.first?.installationToken) // No network credential needed yet.
        first.invalidate()
        let restored = try BarkyClient(configuration: config, storage: storage)
        XCTAssertEqual(restored.barkyID, original)
        try restored.resetSession()
        let fresh = try BarkyClient(configuration: config, storage: storage)
        XCTAssertNotEqual(fresh.barkyID, original)
        let otherConfig = BarkyConfiguration(apiKey: "bk_sdk_" + String(repeating: "q", count: 43), propertyCollection: .disabled)
        let other = try BarkyClient(configuration: otherConfig, storage: storage)
        XCTAssertNotEqual(other.barkyID, fresh.barkyID)
        fresh.invalidate(); other.invalidate()
    }

    func testAutomaticCollectionStartsWithoutChatAndPreservesDeviceIdentity() async throws {
        var config = configuration()
        config.propertyCollection = .init()
        let storage = MemoryStorage()
        let requests = Locked<[[String: Any]]>([])
        let transport = StubURLProtocol.session { request in
            XCTAssertTrue(request.url!.path.hasSuffix("customer/properties"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer bk_session_test")
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            requests.withValue { $0.append(body) }
            return (200, "{\"barkyId\":\"\(body["barkyId"] as! String)\"}")
        }
        let client = try BarkyClient(configuration: config, storage: storage, session: transport)
        for _ in 0..<200 where client.barkyID == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotNil(UUID(uuidString: client.barkyID ?? ""))
        XCTAssertNotEqual(client.barkyID, "customer-a")
        XCTAssertFalse(client.isReady) // No chat has been opened or polled.
        let first = requests.withValue { $0.first! }
        let device = first["device"] as! [String: Any]
        let system = device["systemProperties"] as! [String: Any]
        XCTAssertEqual(first["barkyId"] as? String, client.barkyID)
        XCTAssertEqual(device["collectIpLocation"] as? Bool, true)
        XCTAssertNotNil(system["os_version"])
        XCTAssertNotNil(system["device_model_identifier"])
        XCTAssertNotNil(system["language"])
        XCTAssertNil(system["device_name"])
        XCTAssertNil(system["ip_address"])
        XCTAssertNil(system["identifier_for_vendor"])
        try await client.syncProperties()
        XCTAssertEqual(requests.withValue { $0.last!["barkyId"] as? String }, first["barkyId"] as? String)
        try client.resetSession()
        XCTAssertTrue(storage.values.isEmpty)
        XCTAssertNil(client.barkyID)
    }

    func testDisabledCollectionAndTypedCustomPatches() async throws {
        let bodies = Locked<[[String: Any]]>([])
        let client = try BarkyClient(configuration: configuration(), storage: MemoryStorage(), session: StubURLProtocol.session { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            bodies.withValue { $0.append(body) }
            return (200, "{\"barkyId\":\"\(body["barkyId"] as! String)\"}")
        })
        await client.refresh()
        XCTAssertEqual(bodies.withValue { $0.count }, 0)
        try await client.setUserProperties(["plan": "pro", "visits": 3, "beta": true, "tags": ["a", "b"], "old": .null])
        XCTAssertNil(bodies.withValue { $0[0]["device"] })
        let user = bodies.withValue { $0[0]["userProperties"] as! [String: Any] }
        XCTAssertEqual(user["visits"] as? Int, 3)
        XCTAssertTrue(user["old"] is NSNull)
        try await client.setDeviceProperties(["appearance": "dark"])
        let device = bodies.withValue { $0[1]["device"] as! [String: Any] }
        XCTAssertEqual(device["collectIpLocation"] as? Bool, false)
        XCTAssertTrue((device["systemProperties"] as! [String: Any]).isEmpty)
        client.invalidate()
    }

    func testValidationRejectsReservedOversizedDeepAndNonFiniteValues() throws {
        for values: BarkyProperties in [
            ["barky_id": "forged"], ["$country": "KR"], ["nested": ["constructor": true]],
            ["large": .string(String(repeating: "한", count: 3000))], ["number": .number(.infinity)],
            ["a": ["b": ["c": ["d": ["e": ["f": true]]]]]],
        ] { XCTAssertThrowsError(try PropertyValidation.validate(values)) }
        try PropertyValidation.validate(["valid": ["a", 1, false, nil], "removed": .null])
    }

    func testPropertyFailureDoesNotBlockChatAndCanBeRetried() async throws {
        let fail = Locked(true)
        let client = try BarkyClient(configuration: configuration(), storage: MemoryStorage(), session: StubURLProtocol.session { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            return fail.withValue { $0 } ? (503, "{\"error\":{\"code\":\"unavailable\"}}") : (200, "{\"barkyId\":\"\(body["barkyId"] as! String)\"}")
        })
        do { try await client.setUserProperties(["plan": "free"]); XCTFail("Expected failure") } catch {}
        XCTAssertNotNil(client.propertySyncError)
        await client.refresh()
        XCTAssertTrue(client.isReady)
        XCTAssertNil(client.lastError)
        fail.withValue { $0 = false }
        try await client.setUserProperties(["plan": "free"])
        XCTAssertNil(client.propertySyncError)
        client.invalidate()
    }

    func testDeviceKeySurvivesMessagePersistenceAndChangesWithCustomer() async throws {
        let storage = MemoryStorage()
        let config = configuration()
        let key = KeychainChatStorage.key(configuration: config, customerID: "customer-a")
        let id = UUID().uuidString
        storage.values[key] = StoredChat(barkyID: id)
        let client = try BarkyClient(configuration: config, storage: storage, session: StubURLProtocol.session { request in
            if request.httpMethod == "POST" { return (201, receipt) }
            return (200, page([message("m1", position: 1)], cursor: 1))
        })
        await client.refresh()
        client.draft = "Hello"
        client.send()
        await waitForSend(client)
        XCTAssertEqual(storage.values[key]?.barkyID, id)
        XCTAssertNotEqual(key, KeychainChatStorage.key(configuration: config, customerID: "customer-b"))
        client.invalidate()
    }
}
