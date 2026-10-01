import Foundation
import Testing

@testable import SukiruCore

/// The `JSONValue` tree backs unknown-field preservation in the lock readers
/// unknown keys must survive decoding and be surfaced,
/// never dropped.
@Suite("JSONValue tree")
struct JSONValueTests {
    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test("Decodes every scalar shape with the right case")
    func scalarShapes() throws {
        #expect(try decode("null") == .null)
        #expect(try decode("true") == .bool(true))
        #expect(try decode("false") == .bool(false))
        #expect(try decode("42") == .int(42))
        #expect(try decode("2.5") == .double(2.5))
        #expect(try decode("\"hello\"") == .string("hello"))
    }

    @Test("Booleans never collapse into numbers")
    func boolVersusNumber() throws {
        let value = try decode("{\"flag\": true, \"count\": 1}")
        #expect(value["flag"] == .bool(true))
        #expect(value["count"] == .int(1))
    }

    @Test("Nested arrays and objects round-trip")
    func nesting() throws {
        let value = try decode("{\"a\": [{\"b\": [1, 2]}, \"x\"]}")
        #expect(value["a"]?.arrayValue?.count == 2)
        #expect(value["a"]?.arrayValue?.first?["b"] == .array([.int(1), .int(2)]))
        #expect(value["a"]?.arrayValue?.last == .string("x"))
    }

    @Test("Typed accessors return nil across shapes")
    func typedAccessors() throws {
        #expect(JSONValue.string("s").stringValue == "s")
        #expect(JSONValue.int(3).stringValue == nil)
        #expect(JSONValue.int(3).intValue == 3)
        #expect(JSONValue.bool(true).boolValue == true)
        #expect(JSONValue.double(1.5).doubleValue == 1.5)
        #expect(JSONValue.double(1.5).intValue == nil)
        #expect(JSONValue.null.objectValue == nil)
    }

    @Test("Object subscript returns nil for missing keys and non-objects")
    func objectSubscript() throws {
        let value = try decode("{\"present\": 1}")
        #expect(value["present"] == .int(1))
        #expect(value["absent"] == nil)
        #expect(JSONValue.string("s")["present"] == nil)
    }

    @Test("Encoding is deterministic and preserves values")
    func deterministicEncoding() throws {
        let value = try decode("{\"z\": 1, \"a\": {\"y\": [true, null], \"b\": \"s\"}}")
        let first = try deterministicJSONData(value)
        let second = try deterministicJSONData(value)
        #expect(first == second)
        let text = try #require(String(bytes: first, encoding: .utf8))
        #expect(text.range(of: "\"a\"")!.lowerBound < text.range(of: "\"z\"")!.lowerBound)
        let roundTrip = try JSONDecoder().decode(JSONValue.self, from: first)
        #expect(roundTrip == value)
    }

    @Test("Unknown lock-style fields survive decoding untouched")
    func unknownLockFields() throws {
        let lock = try decode(
            "{\"version\": 3, \"channel\": \"beta\", \"nested\": {\"x\": [1, 2.5, \"s\"]}}"
        )
        #expect(lock["channel"] == .string("beta"))
        #expect(lock["nested"]?["x"] == .array([.int(1), .double(2.5), .string("s")]))
    }
}
