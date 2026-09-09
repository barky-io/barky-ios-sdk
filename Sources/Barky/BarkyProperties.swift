import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Darwin)
import Darwin
#endif

/// A JSON value. A top-level `.null` removes a custom property.
public indirect enum BarkyPropertyValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([BarkyPropertyValue])
    case object([String: BarkyPropertyValue]), null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode([BarkyPropertyValue].self) { self = .array(item) }
        else { self = .object(try value.decode([String: BarkyPropertyValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }
}

extension BarkyPropertyValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: BarkyPropertyValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, BarkyPropertyValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, new in new }))
    }
    public init(nilLiteral: ()) { self = .null }
}

public typealias BarkyProperties = [String: BarkyPropertyValue]

/// Automatic collection starts at configuration. Disable before configuring if
/// your app needs consent first. No GPS, advertising ID, or hardware ID is read.
public struct BarkyPropertyCollection: Sendable {
    public var systemProperties: Bool
    public var ipLocation: Bool
    public init(systemProperties: Bool = true, ipLocation: Bool = true) {
        self.systemProperties = systemProperties
        self.ipLocation = ipLocation
    }
    public static let disabled = BarkyPropertyCollection(systemProperties: false, ipLocation: false)
    var isEnabled: Bool { systemProperties || ipLocation }
}

enum PropertyValidation {
    static func validate(_ properties: BarkyProperties) throws {
        guard properties.count <= 100, valid(.object(properties), depth: 0),
              let encoded = try? JSONEncoder().encode(properties), encoded.count <= 8192
        else { throw BarkyError.invalidProperties }
    }
    private static func valid(_ value: BarkyPropertyValue, depth: Int) -> Bool {
        guard depth <= 5 else { return false }
        switch value {
        case .number(let item): return item.isFinite
        case .array(let items): return items.allSatisfy { valid($0, depth: depth + 1) }
        case .object(let items):
            return items.allSatisfy { key, item in
                !key.isEmpty && key.utf16.count <= 100 && !key.hasPrefix("$") && !key.hasPrefix("barky_") &&
                !["__proto__", "constructor", "prototype"].contains(key) && valid(item, depth: depth + 1)
            }
        default: return true
        }
    }
}

@MainActor
enum SystemProperties {
    static func collect(bundle: Bundle = .main, locale: Locale = .current) -> BarkyProperties {
        var values: BarkyProperties = [
            "device_manufacturer": "Apple", "sdk_version": "0.5.0",
            "locale": .string(locale.identifier), "timezone": .string(TimeZone.current.identifier),
            "languages": .array(Locale.preferredLanguages.prefix(20).map { .string($0) }),
        ]
        values["language"] = Locale.preferredLanguages.first.map { .string($0) }
        values["region"] = (locale.region?.identifier).map { .string($0) }
        values["app_bundle_id"] = bundle.bundleIdentifier.map { .string($0) }
        values["app_version"] = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { .string($0) }
        values["app_build"] = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).map { .string($0) }
        #if canImport(UIKit)
        values["platform"] = "iOS"
        values["device_model"] = .string(UIDevice.current.model)
        values["os_name"] = .string(UIDevice.current.systemName)
        values["os_version"] = .string(UIDevice.current.systemVersion)
        #else
        values["platform"] = "macOS"
        values["device_model"] = "Mac"
        values["os_name"] = "macOS"
        let version = ProcessInfo.processInfo.operatingSystemVersion
        values["os_version"] = .string("\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
        #endif
        #if canImport(Darwin)
        var info = utsname()
        if uname(&info) == 0 {
            let model = withUnsafeBytes(of: &info.machine) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            values["device_model_identifier"] = .string(model)
        }
        #endif
        #if targetEnvironment(simulator)
        values["is_simulator"] = true
        if let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            values["device_model_identifier"] = .string(model)
        }
        #else
        values["is_simulator"] = false
        #endif
        return values
    }
}

struct PropertyUpdate: Encodable {
    struct Device: Encodable {
        let systemProperties: BarkyProperties
        let properties: BarkyProperties?
        let collectIpLocation: Bool
    }
    let barkyId: String
    let userProperties: BarkyProperties?
    let device: Device?
}

@MainActor
final class PropertyController {
    let api: BarkyAPI
    private var tail: Task<Void, Never>?
    private var disconnected = false
    private var lastAutomaticAttempt: Date?
    private(set) var storageKey: String?
    init(api: BarkyAPI) { self.api = api }
    func disconnect() { disconnected = true; tail?.cancel() }
    func shouldCollect() -> Bool {
        guard api.configuration.propertyCollection.isEnabled,
              lastAutomaticAttempt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return false }
        lastAutomaticAttempt = Date()
        return true
    }

    func update(user: BarkyProperties? = nil, device: BarkyProperties? = nil) async throws -> String {
        if let user { try PropertyValidation.validate(user) }
        if let device { try PropertyValidation.validate(device) }
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            guard !self.disconnected else { throw CancellationError() }
            let session = try await self.api.authenticate()
            guard !self.disconnected else { throw CancellationError() }
            let collection = self.api.configuration.propertyCollection
            let barkyID = try self.api.localBarkyID(customerID: session.customerID)
            self.storageKey = KeychainChatStorage.key(configuration: self.api.configuration, customerID: session.customerID)
            var deviceUpdate: PropertyUpdate.Device?
            if collection.isEnabled || device != nil {
                deviceUpdate = .init(systemProperties: collection.systemProperties ? SystemProperties.collect() : [:],
                                     properties: device, collectIpLocation: collection.ipLocation)
            }
            let id = try await self.api.updateProperties(.init(barkyId: barkyID, userProperties: user, device: deviceUpdate))
            guard id == barkyID else { throw BarkyError.invalidResponse }
            guard !self.disconnected else { throw CancellationError() }
            return barkyID
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
