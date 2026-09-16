/// Shared settings contract; the server owns validation, account binding, and available choices.
import Foundation

public enum AssistantSettings {
    public typealias Transport = @MainActor (String, [String: Value]?) async throws -> Response
    public struct Response: Decodable, Sendable { public let settings: Settings }
    public struct Settings: Decodable, Sendable {
        public let enabled: Bool
        let accounts: [Account]?
        let calendarAccounts: [Account]?
        let selectedAccount: Int?
        let aliases: [Address]?
        let identity: [String: Value]?
        let preferences: [String: Value]?
        let timezones: [Timezone]?
        let numericPreferences: [NumericPreference]?
        let error: String?
        enum CodingKeys: String, CodingKey {
            case enabled, accounts, aliases, identity, preferences, timezones, error
            case selectedAccount = "selected_account", numericPreferences = "numeric_preferences"
            case calendarAccounts = "calendar_accounts"
        }
    }
    struct Account: Decodable, Identifiable, Sendable { let id: Int; let label: String }
    struct Address: Decodable, Sendable { let email: String; let primary: Bool }
    struct Timezone: Decodable, Sendable { let value: String; let label: String }
    struct NumericPreference: Decodable, Sendable {
        let key: String; let label: String; let min: Int; let max: Int
    }
    public enum Value: Codable, Sendable {
        case string(String), integer(Int), bool(Bool), integers([Int]), null
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Int.self) { self = .integer(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else { self = .integers(try c.decode([Int].self)) }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let v): try c.encode(v)
            case .integer(let v): try c.encode(v)
            case .bool(let v): try c.encode(v)
            case .integers(let v): try c.encode(v)
            case .null: try c.encodeNil()
            }
        }
        var string: String { if case .string(let v) = self { return v }; return "" }
        var integer: Int { if case .integer(let v) = self { return v }; return 0 }
        var bool: Bool { if case .bool(let v) = self { return v }; return false }
        var integers: [Int] { if case .integers(let v) = self { return v }; return [] }
    }
}
