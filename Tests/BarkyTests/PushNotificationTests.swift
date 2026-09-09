import Foundation
import XCTest
@testable import Barky

final class PushNotificationTests: XCTestCase {
    private let registrationID = "00000000-0000-4000-8000-000000000010"
    private let customerID = "00000000-0000-4000-8000-000000000020"
    private let replyID = "00000000-0000-4000-8000-000000000030"

    private func notification(customer: String? = nil) -> [AnyHashable: Any] {
        ["aps": ["alert": "New reply"], "barky": ["version": 1, "conversationId": conversationID,
            "messageId": replyID, "customerId": customer ?? customerID]]
    }

    func testIgnoresOtherNotificationsAndMalformedRoutingHints() {
        XCTAssertNil(BarkyPushNotification(userInfo: ["aps": ["alert": "Other app"]]))
        var malformed = notification()
        malformed["barky"] = ["version": 2, "conversationId": conversationID, "messageId": replyID, "customerId": customerID]
        XCTAssertNil(BarkyPushNotification(userInfo: malformed))
        malformed["barky"] = ["version": 1, "conversationId": "../../admin", "messageId": replyID, "customerId": customerID]
        XCTAssertNil(BarkyPushNotification(userInfo: malformed))
        XCTAssertEqual(BarkyPushNotification(userInfo: notification())?.conversationID, conversationID)
    }

    @MainActor
    func testRegistrationUsesPrivateSessionAndCleanupSurvivesClientRecreation() async throws {
        let requests = Locked<[URLRequest]>([])
        let storage = MemoryStorage()
        let registrationID = registrationID, customerID = customerID
        let transport = StubURLProtocol.session { request in
            requests.withValue { $0.append(request) }
            if request.url!.path.hasSuffix("unregister") { return (200, "{\"ok\":true}") }
            return (200, "{\"registrationId\":\"\(registrationID)\"}")
        }
        let client = try BarkyClient(configuration: configuration(provider: { session(customer: customerID) }), storage: storage, session: transport)
        try await client.registerForPushNotifications(deviceToken: Data([0, 1, 15, 255]), environment: .sandbox, bundleID: "com.example.app")
        let request = requests.withValue { $0[0] }
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer bk_session_test")
        let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: String]
        XCTAssertEqual(body, ["deviceToken": "00010fff", "environment": "sandbox", "bundleId": "com.example.app"])
        let encoded = String(decoding: try JSONEncoder().encode(Array(storage.values.values)), as: UTF8.self)
        XCTAssertFalse(encoded.contains("00010fff"), "Do not cache the APNs device token in the app")
        let recreated = try BarkyClient(configuration: configuration(provider: { session(customer: customerID) }), storage: storage, session: transport)
        try await recreated.disablePushNotifications()
        XCTAssertEqual(requests.withValue { $0.count }, 2)
        XCTAssertTrue(storage.values.values.allSatisfy { $0.pushRegistration == nil })
        client.invalidate(); recreated.invalidate()
    }

    @MainActor
    func testCleanupFailureKeepsRegistrationAndDoesNotResetIdentity() async throws {
        let storage = MemoryStorage()
        let fail = Locked(true)
        let registrationID = registrationID, customerID = customerID
        let transport = StubURLProtocol.session { request in
            if request.url!.path.hasSuffix("unregister") {
                if fail.withValue({ $0 }) { throw URLError(.notConnectedToInternet) }
                return (200, "{\"ok\":true}")
            }
            return (200, "{\"registrationId\":\"\(registrationID)\"}")
        }
        let client = try BarkyClient(configuration: configuration(provider: { session(customer: customerID) }), storage: storage, session: transport)
        try await client.registerForPushNotifications(deviceToken: Data([1, 2]), environment: .production, bundleID: "com.example.app")
        do { try await client.resetSessionWithPushCleanup(); XCTFail("Must surface cleanup failure") } catch { }
        XCTAssertTrue(storage.values.values.contains { $0.pushRegistration != nil })
        fail.withValue { $0 = false }
        try await client.resetSessionWithPushCleanup()
        XCTAssertTrue(storage.values.values.allSatisfy { $0.pushRegistration == nil })
    }

    @MainActor
    func testNotificationChecksCustomerAndServerOwnershipBeforeOpeningChat() async throws {
        let requests = Locked<[URLRequest]>([])
        let customerID = customerID
        let transport = StubURLProtocol.session { request in
            requests.withValue { $0.append(request) }
            return (200, page([message("m1", position: 1)], cursor: 1))
        }
        let client = try BarkyClient(configuration: configuration(provider: { session(customer: customerID) }), storage: MemoryStorage(), session: transport)
        let other = try await client.handlePushNotification(notification(customer: "00000000-0000-4000-8000-000000000099"))
        XCTAssertFalse(other)
        XCTAssertTrue(requests.withValue { $0.isEmpty })
        let opened = try await client.handlePushNotification(notification())
        XCTAssertTrue(opened)
        XCTAssertEqual(client.conversationID, conversationID)
        XCTAssertFalse(requests.withValue { $0.contains { $0.url!.path.hasSuffix("read-receipts") } }, "Notification taps do not imply reading")
        client.invalidate()
    }

    @MainActor
    func testForeignConversationIsRejectedWithoutChangingLocalState() async throws {
        let customerID = customerID
        let transport = StubURLProtocol.session { _ in (404, "{\"error\":{\"code\":\"not_found\"}}") }
        let client = try BarkyClient(configuration: configuration(provider: { session(customer: customerID) }), storage: MemoryStorage(), session: transport)
        let opened = try await client.handlePushNotification(notification())
        XCTAssertFalse(opened)
        XCTAssertNil(client.conversationID)
        XCTAssertTrue(client.messages.isEmpty)
        client.invalidate()
    }

    @MainActor
    func testUnconfiguredPushAndInvalidDeviceTokensDoNotSendRequests() async throws {
        let count = Locked(0)
        let transport = StubURLProtocol.session { _ in count.withValue { $0 += 1 }; return (500, "{}") }
        let client = try BarkyClient(configuration: configuration(), storage: MemoryStorage(), session: transport)
        do { try await client.registerForPushNotifications(deviceToken: Data(), environment: .sandbox, bundleID: "com.example.app"); XCTFail("Empty token") } catch { XCTAssertEqual(error as? BarkyError, .invalidConfiguration) }
        XCTAssertEqual(count.withValue { $0 }, 0)
        client.invalidate()
        do { try await client.disablePushNotifications(); XCTFail("Not configured") } catch { XCTAssertEqual(error as? BarkyError, .notConfigured) }
    }
}
