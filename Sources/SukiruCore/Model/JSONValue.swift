import Foundation

/// A JSON document tree with typed accessors.
///
/// Lock files are decoded into this tree instead of a fixed `Codable` struct
/// so that unknown keys — entry-level and top-level — survive a read and are
/// surfaced rather than dropped (architecture §4.1, port-reference §6: the
/// archive's `extra` flatten maps are load-bearing). Key order is NOT
/// preserved; Sukiru never writes locks, so order is not load-bearing.
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {
    /// The string, or nil for any other shape.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The bool, or nil for any other shape (never coerced from numbers).
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The integer, or nil for any other shape (never coerced from doubles).
    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    /// The double, or nil for any other shape.
    public var doubleValue: Double? {
        if case .double(let value) = self { return value }
        return nil
    }

    /// The array elements, or nil for any other shape.
    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// The object members, or nil for any other shape.
    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Object member lookup; nil for missing keys and non-objects.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}
