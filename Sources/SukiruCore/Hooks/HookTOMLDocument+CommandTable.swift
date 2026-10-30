import Foundation

/// jcode's `[hooks]` table: each key is an event whose value is a command or a one-line array.
extension HookTOMLDocument {
    /// One jcode `event = "command"` or `event = ["a", "b"]` line; numeric settings are skipped.
    mutating func commandField(_ line: String, at index: Int) throws {
        guard let equal = line.firstIndex(of: "=") else {
            throw HookError("Malformed hook TOML field")
        }
        let key = line[..<equal].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            throw HookError("Unsupported hook key; source is read-only")
        }
        let literals: [String]
        if value.hasPrefix("[") {
            guard value.hasSuffix("]") else {
                throw HookError("Multi-line hook command arrays are read-only")
            }
            literals = try Self.stringLiterals(String(value.dropFirst().dropLast()))
        } else if value.hasPrefix("\"") || value.hasPrefix("'") {
            literals = [value]
        } else {
            return
        }
        guard !literals.isEmpty else { return }
        let group = Group(
            event: key, index: groups.filter { $0.event == key }.count, lines: index..<index + 1)
        groups.append(group)
        for (offset, literal) in literals.enumerated() {
            handlers.append(
                Handler(
                    event: key, group: group.index, index: offset,
                    details: ["command": try Self.value(literal)], lines: index..<index + 1,
                    literal: literal))
        }
    }

    /// Splits a one-line array body into its string literals; any other element is refused.
    static func stringLiterals(_ body: String) throws -> [String] {
        var literals: [String] = []
        var rest = Substring(body)
        while true {
            rest = rest.drop { $0 == " " || $0 == "\t" }
            guard let quote = rest.first else { return literals }
            guard quote == "\"" || quote == "'" else {
                throw HookError("Unsupported hook command array; source is read-only")
            }
            var end = rest.index(after: rest.startIndex)
            while end < rest.endIndex && rest[end] != quote {
                if rest[end] == "\\" && quote == "\"" && rest.index(after: end) < rest.endIndex {
                    end = rest.index(after: end)
                }
                end = rest.index(after: end)
            }
            guard end < rest.endIndex else { throw HookError("Unterminated TOML string") }
            literals.append(String(rest[...end]))
            rest = rest[rest.index(after: end)...].drop { $0 == " " || $0 == "\t" }
            guard let separator = rest.first else { return literals }
            guard separator == "," else {
                throw HookError("Unsupported hook command array; source is read-only")
            }
            rest = rest.dropFirst()
        }
    }
}
