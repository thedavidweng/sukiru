import Foundation

/// Encodes a value as deterministic, human-readable JSON (sorted keys,
/// pretty-printed, un-escaped slashes) so identical inputs yield byte-identical
/// output and paths stay readable when eyeballed.
func deterministicJSONData<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
