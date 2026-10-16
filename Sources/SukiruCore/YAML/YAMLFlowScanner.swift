import Foundation

/// Single-buffer scanner for quoted scalars, flow collections and keys.
struct InlineScanner {
    var text: String
    var index: String.Index
    /// Anchors defined inside the scanned fragment (merged by the caller).
    var anchorValues: [String: YAMLNode] = [:]

    init(text: String) {
        self.text = text
        self.index = text.startIndex
    }

    var atEnd: Bool { index >= text.endIndex }
    var remainder: String { String(text[index...]) }

    mutating func skipSpaces() {
        while !atEnd {
            let char = text[index]
            guard char == " " || char == "\t" || char == "\n" else { break }
            index = text.index(after: index)
        }
    }

    /// Parses a key/value scalar fragment (plain or quoted, no flow).
    mutating func parseScalarFragment() throws -> YAMLNode {
        skipSpaces()
        guard !atEnd else { throw YAMLError("expected a scalar") }
        if text[index] == "'" || text[index] == "\"" {
            guard let node = try parseQuoted(balanceRequired: true) else {
                throw YAMLError("unterminated quoted scalar")
            }
            return node
        }
        if text[index] == "[" || text[index] == "{" {
            return try parseFlow()
        }
        // Plain fragment: to end (key context validates separately).
        let raw = remainder.trimmingCharacters(in: .whitespaces)
        index = text.endIndex
        return .scalar(YAMLScalar(raw, tag: YAMLTagResolution.resolve(plain: raw)))
    }

    /// Parses a quoted scalar at the cursor. With `balanceRequired: false`,
    /// returns nil (without consuming) when unterminated.
    mutating func parseQuoted(balanceRequired: Bool) throws -> YAMLNode? {
        guard !atEnd else {
            if balanceRequired { throw YAMLError("unterminated quoted scalar") }
            return nil
        }
        if text[index] == "'" {
            return try parseSingleQuoted(balanceRequired: balanceRequired)
        }
        return try parseDoubleQuoted(balanceRequired: balanceRequired)
    }

    private mutating func parseSingleQuoted(balanceRequired: Bool) throws -> YAMLNode? {
        var result = ""
        var cursor = text.index(after: index)
        while cursor < text.endIndex {
            if text[cursor] == "'" {
                let next = text.index(after: cursor)
                if next < text.endIndex, text[next] == "'" {
                    result.append("'")
                    cursor = text.index(after: next)
                    continue
                }
                index = next
                return .scalar(YAMLScalar(result, tag: .str))
            }
            result.append(text[cursor])
            cursor = text.index(after: cursor)
        }
        if balanceRequired { throw YAMLError("unterminated single-quoted scalar") }
        return nil
    }

    private mutating func parseDoubleQuoted(balanceRequired: Bool) throws -> YAMLNode? {
        var result = ""
        var cursor = text.index(after: index)
        while cursor < text.endIndex {
            let char = text[cursor]
            if char == "\"" {
                index = text.index(after: cursor)
                return .scalar(YAMLScalar(result, tag: .str))
            }
            if char == "\\" {
                let escape = try parseEscapeSequence(from: cursor)
                result.append(escape.value)
                cursor = escape.next
                continue
            }
            result.append(char)
            cursor = text.index(after: cursor)
        }
        if balanceRequired { throw YAMLError("unterminated double-quoted scalar") }
        return nil
    }

    /// Parses an escape starting at the backslash; returns value and cursor
    /// past the sequence.
    private func parseEscapeSequence(
        from backslash: String.Index
    ) throws -> (value: String, next: String.Index) {
        let cursor = text.index(after: backslash)
        guard cursor < text.endIndex else {
            throw YAMLError("unterminated escape sequence")
        }
        let esc = text[cursor]
        if esc == "x" || esc == "u" || esc == "U" {
            return try variableEscape(esc, from: cursor)
        }
        guard let value = Self.fixedEscape(esc) else {
            throw YAMLError("invalid escape \\\(esc)")
        }
        return (value, text.index(after: cursor))
    }

    private func variableEscape(
        _ esc: Character, from cursor: String.Index
    ) throws -> (value: String, next: String.Index) {
        let label = "\\\(esc)"
        let count = esc == "x" ? 2 : esc == "u" ? 4 : 8
        let hex = text.index(after: cursor)
        guard let value = Self.hexValue(text, from: hex, count: count) else {
            throw YAMLError("invalid \(label) escape")
        }
        if esc == "x" {
            return (String(Character(UnicodeScalar(value)!)), text.index(hex, offsetBy: count))
        }
        guard let scalar = UnicodeScalar(value) else {
            throw YAMLError("invalid \(label) escape")
        }
        return (String(Character(scalar)), text.index(hex, offsetBy: count))
    }

    private static let fixedEscapes: [Character: String] = [
        "n": "\n", "t": "\t", "r": "\r", "\\": "\\", "\"": "\"", "/": "/",
        "0": "\0", "a": "\u{7}", "b": "\u{8}", "e": "\u{1B}", "f": "\u{c}",
        "v": "\u{b}", " ": " ", "\n": ""
    ]

    private static func fixedEscape(_ esc: Character) -> String? {
        fixedEscapes[esc]
    }

    private static func hexValue(
        _ text: String, from start: String.Index, count: Int
    ) -> UInt32? {
        var cursor = start
        var value: UInt32 = 0
        for _ in 0..<count {
            guard cursor < text.endIndex else { return nil }
            guard let digit = text[cursor].hexDigitValue else { return nil }
            value = value * 16 + UInt32(digit)
            cursor = text.index(after: cursor)
        }
        return value
    }
}
