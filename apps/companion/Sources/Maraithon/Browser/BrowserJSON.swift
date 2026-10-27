/// Sendable JSON keeps DevTools messages inside actors without untyped values crossing isolation.
import Foundation

indirect enum BrowserJSON: Codable, Sendable {
    case object([String: BrowserJSON]), array([BrowserJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode([String: BrowserJSON].self) { self = .object(v) }
        else { self = .array(try value.decode([BrowserJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
    subscript(_ key: String) -> BrowserJSON { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var integer: Int? { if case .number(let v) = self { return Int(v) }; return nil }
    var array: [BrowserJSON] { if case .array(let v) = self { return v }; return [] }
    static func strings(_ values: [String: String]) -> BrowserJSON { .object(values.mapValues { .string($0) }) }
}
