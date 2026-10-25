import Foundation

/// First-party YAML 1.2 subset parser (Apple-only policy; replaces Yams).
///
/// Covers the repository's documented contract — skill frontmatter and hook
/// declarations: block mappings/sequences, flow collections, single- and
/// double-quoted scalars with escapes, literal/folded block scalars with
/// chomping, anchors/aliases, explicit `!!` tags, `#` comments and nested
/// structures. Anything outside the subset throws ``YAMLError`` so callers
/// surface an `Issue` instead of silently misreading input.
public struct YAMLTag: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let str = YAMLTag("tag:yaml.org,2002:str")
    public static let bool = YAMLTag("tag:yaml.org,2002:bool")
    public static let int = YAMLTag("tag:yaml.org,2002:int")
    public static let float = YAMLTag("tag:yaml.org,2002:float")
    public static let null = YAMLTag("tag:yaml.org,2002:null")
    public static let seq = YAMLTag("tag:yaml.org,2002:seq")
    public static let map = YAMLTag("tag:yaml.org,2002:map")
}

/// A scalar value with its resolved tag.
public struct YAMLScalar: Sendable {
    public let string: String
    public let tag: YAMLTag
    public init(_ string: String, tag: YAMLTag) {
        self.string = string
        self.tag = tag
    }
}

/// A mapping pair with scalar-or-better key semantics.
public struct YAMLPair: Sendable {
    public let key: YAMLNode
    public let value: YAMLNode
    public init(key: YAMLNode, value: YAMLNode) {
        self.key = key
        self.value = value
    }
}

/// A mapping as an ordered pair list (duplicate keys: last wins on lookup).
public struct YAMLMapping: Sendable {
    public var pairs: [YAMLPair]
    public init(_ pairs: [YAMLPair] = []) {
        self.pairs = pairs
    }

    public subscript(_ key: String) -> YAMLNode? {
        var found: YAMLNode?
        for pair in pairs where pair.key.string == key {
            found = pair.value
        }
        return found
    }
}

public indirect enum YAMLNode: Sendable {
    case scalar(YAMLScalar)
    case mapping(YAMLMapping)
    case sequence([YAMLNode])

    public var tag: YAMLTag {
        switch self {
        case .scalar(let scalar): return scalar.tag
        case .mapping: return .map
        case .sequence: return .seq
        }
    }

    /// The scalar string, or nil for collections.
    public var string: String? {
        if case .scalar(let scalar) = self { return scalar.string }
        return nil
    }

    /// The bool value for `bool`-tagged scalars, else nil.
    public var bool: Bool? {
        guard tag == .bool, let raw = string else { return nil }
        switch raw {
        case "true", "True", "TRUE": return true
        case "false", "False", "FALSE": return false
        default: return nil
        }
    }

    public var intValue: Int? {
        guard tag == .int, let raw = string else { return nil }
        return YAMLIntegers.parse(raw)
    }

    public var doubleValue: Double? {
        guard tag == .float, let raw = string else { return nil }
        return YAMLFloats.parse(raw)
    }
}

public struct YAMLError: LocalizedError, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

public enum YAMLSubset {
    /// Parses a single YAML document; nil for empty/blank input.
    public static func compose(yaml text: String) throws -> YAMLNode? {
        var parser = LineParser(text: text)
        guard parser.hasContent() else { return nil }
        let node = try parser.parseBlock(minIndent: 0)
        // Trailing content after the root document is an error.
        if parser.hasContent() {
            throw YAMLError("unexpected content after document root")
        }
        return node
    }

    /// Parses YAML and converts it to a ``JSONValue`` tree (for hook
    /// frontmatter, mirroring the previous `YAMLDecoder` use).
    public static func jsonValue(yaml text: String) throws -> JSONValue {
        guard let node = try compose(yaml: text) else { return .object([:]) }
        return try convert(node)
    }

    private static func convert(_ node: YAMLNode) throws -> JSONValue {
        switch node {
        case .scalar(let scalar):
            return try convertScalar(scalar, node: node)
        case .sequence(let items):
            return .array(try items.map(convert))
        case .mapping(let mapping):
            return try convertMapping(mapping)
        }
    }

    private static func convertScalar(
        _ scalar: YAMLScalar, node: YAMLNode
    ) throws -> JSONValue {
        switch scalar.tag {
        case .null:
            return .null
        case .bool:
            guard let value = node.bool else {
                throw YAMLError("invalid bool scalar: \(scalar.string)")
            }
            return .bool(value)
        case .int:
            guard let value = node.intValue else {
                throw YAMLError("invalid int scalar: \(scalar.string)")
            }
            return .int(value)
        case .float:
            guard let value = node.doubleValue else {
                throw YAMLError("invalid float scalar: \(scalar.string)")
            }
            return .double(value)
        default:
            return .string(scalar.string)
        }
    }

    private static func convertMapping(_ mapping: YAMLMapping) throws -> JSONValue {
        var object: [String: JSONValue] = [:]
        for pair in mapping.pairs {
            guard let key = pair.key.string else {
                throw YAMLError("non-scalar mapping key")
            }
            object[key] = try convert(pair.value)
        }
        return .object(object)
    }
}

enum YAMLIntegers {
    static func parse(_ text: String) -> Int? {
        var body = text
        var sign = 1
        if body.hasPrefix("+") {
            body = String(body.dropFirst())
        } else if body.hasPrefix("-") {
            sign = -1
            body = String(body.dropFirst())
        }
        if body.hasPrefix("0x") || body.hasPrefix("0X") {
            guard let value = Int(body.dropFirst(2), radix: 16) else { return nil }
            return sign * value
        }
        if body.hasPrefix("0o") || body.hasPrefix("0O") {
            guard let value = Int(body.dropFirst(2), radix: 8) else { return nil }
            return sign * value
        }
        guard body.allSatisfy(\.isNumber), let value = Int(body) else { return nil }
        return sign * value
    }

    static func isInt(_ text: String) -> Bool { parse(text) != nil }
}

enum YAMLFloats {
    static func parse(_ text: String) -> Double? {
        switch text {
        case ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF": return .infinity
        case "-.inf", "-.Inf", "-.INF": return -.infinity
        case ".nan", ".NaN", ".NAN": return .nan
        default: return Double(text)
        }
    }
}

enum YAMLTagResolution {
    static let boolNames = ["true", "True", "TRUE", "false", "False", "FALSE"]

    static func resolve(plain text: String) -> YAMLTag {
        if text.isEmpty { return .null }
        switch text {
        case "null", "Null", "NULL", "~": return .null
        case "true", "True", "TRUE", "false", "False", "FALSE": return .bool
        default: break
        }
        if YAMLIntegers.isInt(text) { return .int }
        if isFloat(text) { return .float }
        return .str
    }

    static func isFloat(_ text: String) -> Bool {
        var body = text
        if body.hasPrefix("+") || body.hasPrefix("-") {
            body = String(body.dropFirst())
        }
        let named = [".inf", ".Inf", ".INF", ".nan", ".NaN", ".NAN"]
        if named.contains(body) { return true }
        let hasMarker = body.contains(".") || body.contains("e")
        let hasUpperMarker = body.contains("E")
        guard hasMarker || hasUpperMarker else { return false }
        return Double(text) != nil
    }
}

/// A non-blank, non-comment source line with its indent.
struct LocatedLine {
    let line: Int
    let indent: Int
    let content: String
}

/// Anchor/tag operators collected before a value.
struct PendingOps {
    var anchor: String?
    var tag: YAMLTag?
}

/// The pending state of an inline value parse.
enum InlinePending {
    case none
    case nested(PendingOps)
}

/// An inline value with the first unused line.
struct InlineResult {
    var value: YAMLNode?
    var pending: InlinePending
    var nextLine: Int
}

/// A scalar with the first unused line.
struct ScalarConsume {
    var node: YAMLNode
    var nextLine: Int
}
