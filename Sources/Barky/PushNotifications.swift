import Foundation

/// Match the signed app's aps-environment entitlement. TestFlight/App Store use production.
public enum BarkyPushEnvironment: String, Codable, Sendable {
    case sandbox
    case production
}

/// A routing hint, not an authorization credential. Opening it still checks the session.
public struct BarkyPushNotification: Equatable, Sendable {
    public let conversationID: String
    public let messageID: String
    public let customerID: String

    public init?(userInfo: [AnyHashable: Any]) {
        guard let value = userInfo["barky"] as? [String: Any],
              value["version"] as? Int == 1,
              let conversation = value["conversationId"] as? String, UUID(uuidString: conversation) != nil,
              let message = value["messageId"] as? String, UUID(uuidString: message) != nil,
              let customer = value["customerId"] as? String, UUID(uuidString: customer) != nil else { return nil }
        conversationID = conversation; messageID = message; customerID = customer
    }
}

struct PushRegistration: Codable, Sendable {
    let id: String
    let customerID: String
}

@MainActor
final class PushRegistrationController {
    private let api: BarkyAPI
    private let storage: ChatStorage
    private let key: String
    private var operation: Task<Void, Error>?
    private var invalidated = false

    init(api: BarkyAPI, storage: ChatStorage) {
        self.api = api; self.storage = storage
        key = KeychainChatStorage.key(configuration: api.configuration, customerID: "sdk-push-registration")
    }

    func register(token: Data, environment: BarkyPushEnvironment, bundleID: String) async throws {
        guard !token.isEmpty, token.count <= 512,
              bundleID.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil,
              bundleID.utf8.count <= 255 else { throw BarkyError.invalidConfiguration }
        try await enqueue {
            let auth = try await self.api.authenticate()
            var state = try self.storage.load(key: self.key)
            let old = state.pushRegistration
            let id = try await self.api.registerPushDevice(token: token, environment: environment, bundleID: bundleID)
            // A disconnect during the request must not write into a new user's state.
            guard !self.invalidated else {
                self.api.unregisterPushBestEffort(registrationID: id, customerID: auth.customerID)
                throw CancellationError()
            }
            state.pushRegistration = PushRegistration(id: id, customerID: auth.customerID)
            do { try self.storage.save(state, key: self.key) }
            catch {
                try? await self.api.unregisterPushDevice(registrationID: id)
                throw error
            }
            if let old, old.id != id, old.customerID == auth.customerID {
                try await self.api.unregisterPushDevice(registrationID: old.id)
            }
        }
    }

    func disable() async throws {
        try await enqueue {
            var state = try self.storage.load(key: self.key)
            guard let registration = state.pushRegistration else { return }
            let auth = try await self.api.authenticate()
            guard registration.customerID == auth.customerID else { throw BarkyError.identityChanged }
            try await self.api.unregisterPushDevice(registrationID: registration.id)
            guard !self.invalidated else { throw CancellationError() }
            state.pushRegistration = nil
            try self.storage.save(state, key: self.key)
        }
    }

    private func enqueue(_ action: @escaping @MainActor () async throws -> Void) async throws {
        guard !invalidated else { throw CancellationError() }
        let previous = operation
        let task = Task { @MainActor in
            _ = try? await previous?.value
            guard !self.invalidated else { throw CancellationError() }
            try await action()
        }
        operation = task
        try await task.value
    }

    // Synchronous logout can only attempt cleanup. Apps changing accounts must await
    // disablePushNotifications() first and handle errors before changing identity.
    func disconnect() {
        invalidated = true
        if let registration = try? storage.load(key: key).pushRegistration {
            api.unregisterPushBestEffort(registrationID: registration.id, customerID: registration.customerID)
        }
    }
}
