import Foundation

/// Where one plugin's `[plugins."<id>"]` table and `enabled` value sit in a
/// Codex `config.toml`, read byte-exactly. Lines inside multi-line strings
/// and arrays are never read as headers or keys. Any other representation of
/// the same plugin (duplicate tables, dotted keys, inline or array tables, a
/// non-boolean value) is refused rather than approximated.
struct CodexPluginLayout {
    struct Line {
        let start: Int
        /// The end of the content, before `\r\n` or `\n`.
        let contentEnd: Int
        /// The end including the terminator.
        let end: Int
    }

    private struct LexState {
        var multiline: UInt8?
        var depth = 0
        var isTop: Bool { multiline == nil && depth == 0 }
    }

    private(set) var header: Line?
    private(set) var valueRange: Range<Int>?
    private(set) var value: Bool?
    private let target: [String]
    private let refuse: (String) -> PluginLifecycleError
    private var table: [String] = []
    private var arrayTable = false

    init(
        _ bytes: [UInt8], identifier: String, refuse: @escaping (String) -> PluginLifecycleError
    ) throws {
        target = ["plugins", identifier]
        self.refuse = refuse
        var state = LexState()
        for line in Self.lines(bytes) {
            let content = Array(bytes[line.start..<line.contentEnd])
            let atTop = state.isTop
            Self.lex(content, &state)
            guard atTop, let first = content.firstIndex(where: { !Self.isBlank($0) }),
                content[first] != Self.hash
            else { continue }
            if content[first] == UInt8(ascii: "[") {
                try readHeader(content, from: first, line: line)
            } else {
                try readKey(content, from: first, line: line)
            }
        }
    }

    private mutating func readHeader(_ content: [UInt8], from first: Int, line: Line) throws {
        let isArray = content.count > first + 1 && content[first + 1] == UInt8(ascii: "[")
        let close = Array(repeating: UInt8(ascii: "]"), count: isArray ? 2 : 1)
        guard let (path, end) = Self.keyPath(content, from: first + close.count),
            content.count >= end + close.count,
            Array(content[end..<end + close.count]) == close,
            Self.restIsBlank(content, from: end + close.count)
        else { throw refuse("a table header is not supported TOML") }
        if isArray, path.starts(with: target) || target.starts(with: path) {
            throw refuse("an array-of-tables representation is not supported")
        }
        if !isArray, path == target {
            guard header == nil else { throw refuse("the table is declared twice") }
            header = line
        }
        table = path
        arrayTable = isArray
    }

    private mutating func readKey(_ content: [UInt8], from first: Int, line: Line) throws {
        guard let (keys, equal) = Self.keyPath(content, from: first),
            equal < content.count, content[equal] == UInt8(ascii: "=")
        else { throw refuse("a line is not a supported TOML key or table") }
        guard !arrayTable else { return }
        if table.starts(with: target) {
            guard table == target, keys == ["enabled"] else { return }
            guard valueRange == nil else { throw refuse("enabled is set twice") }
            let (range, value) = try boolean(content, after: equal)
            valueRange = (line.start + range.lowerBound)..<(line.start + range.upperBound)
            self.value = value
            return
        }
        let full = table + keys
        if full.starts(with: target) || target.starts(with: full) {
            throw refuse("an inline-table or dotted-key representation is not supported")
        }
    }

    /// The range of a bare `true`/`false` value that ends its line.
    private func boolean(_ bytes: [UInt8], after equal: Int) throws -> (Range<Int>, Bool) {
        let start = Self.skipBlank(bytes, from: equal + 1)
        let end =
            bytes[start...].firstIndex(where: { Self.isBlank($0) || $0 == Self.hash })
            ?? bytes.count
        let token = String(bytes: bytes[start..<end], encoding: .utf8) ?? ""
        guard ["true", "false"].contains(token), Self.restIsBlank(bytes, from: end) else {
            throw refuse("enabled is not a single-line boolean")
        }
        return (start..<end, token == "true")
    }

    // MARK: - lexing

    private static let hash = UInt8(ascii: "#")
    private static let quote = UInt8(ascii: "\"")
    private static let apostrophe = UInt8(ascii: "'")
    private static let backslash = UInt8(ascii: "\\")

    private static func lines(_ bytes: [UInt8]) -> [Line] {
        var lines: [Line] = []
        var start = 0
        while start < bytes.count {
            let newline = bytes[start...].firstIndex(of: 0x0A)
            let end = newline.map { $0 + 1 } ?? bytes.count
            var contentEnd = newline ?? bytes.count
            if contentEnd > start, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            lines.append(Line(start: start, contentEnd: contentEnd, end: end))
            start = end
        }
        return lines
    }

    /// Advances the string/bracket state across one line.
    private static func lex(_ bytes: [UInt8], _ state: inout LexState) {
        var index = 0
        while index < bytes.count {
            if let open = state.multiline {
                index = closeMultiline(bytes, from: index, quote: open, state: &state)
                continue
            }
            let byte = bytes[index]
            switch byte {
            case hash:
                return
            case quote, apostrophe:
                if triple(bytes, at: index, byte) {
                    state.multiline = byte
                    index += 3
                } else {
                    index = stringEnd(bytes, from: index) + 1
                }
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                state.depth += 1
                index += 1
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                state.depth = max(0, state.depth - 1)
                index += 1
            default:
                index += 1
            }
        }
    }

    private static func closeMultiline(
        _ bytes: [UInt8], from index: Int, quote open: UInt8, state: inout LexState
    ) -> Int {
        if open == quote && bytes[index] == backslash { return index + 2 }
        guard triple(bytes, at: index, open) else { return index + 1 }
        var next = index + 3
        var extra = 0
        while extra < 2, next < bytes.count, bytes[next] == open {
            next += 1
            extra += 1
        }
        state.multiline = nil
        return next
    }

    /// The index of the closing quote of a single-line string opened at `index`.
    private static func stringEnd(_ bytes: [UInt8], from index: Int) -> Int {
        let open = bytes[index]
        var end = index + 1
        while end < bytes.count, bytes[end] != open {
            if open == quote && bytes[end] == backslash { end += 1 }
            end += 1
        }
        return end
    }

    private static func triple(_ bytes: [UInt8], at index: Int, _ quote: UInt8) -> Bool {
        index + 2 < bytes.count && bytes[index] == quote && bytes[index + 1] == quote
            && bytes[index + 2] == quote
    }

    /// A dotted key of bare or quoted segments, and the index after it.
    private static func keyPath(_ bytes: [UInt8], from start: Int) -> ([String], Int)? {
        var segments: [String] = []
        var index = skipBlank(bytes, from: start)
        while true {
            guard let (segment, end) = keySegment(bytes, at: index) else { return nil }
            segments.append(segment)
            index = skipBlank(bytes, from: end)
            guard index < bytes.count, bytes[index] == UInt8(ascii: ".") else {
                return (segments, index)
            }
            index = skipBlank(bytes, from: index + 1)
        }
    }

    private static func keySegment(_ bytes: [UInt8], at index: Int) -> (String, Int)? {
        guard index < bytes.count else { return nil }
        let byte = bytes[index]
        guard byte == quote || byte == apostrophe else {
            let end = bytes[index...].firstIndex(where: { !isBare($0) }) ?? bytes.count
            guard end > index, let bare = String(bytes: bytes[index..<end], encoding: .utf8)
            else { return nil }
            return (bare, end)
        }
        let end = stringEnd(bytes, from: index)
        guard end < bytes.count,
            let literal = String(bytes: bytes[index...end], encoding: .utf8)
        else { return nil }
        let decoded =
            byte == apostrophe
            ? String(literal.dropFirst().dropLast())
            : try? JSONDecoder().decode(String.self, from: Data(literal.utf8))
        return decoded.map { ($0, end + 1) }
    }

    private static func isBare(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte) || byte == UInt8(ascii: "_")
            || byte == UInt8(ascii: "-")
    }

    private static func isBlank(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }

    private static func skipBlank(_ bytes: [UInt8], from index: Int) -> Int {
        bytes[min(index, bytes.count)...].firstIndex(where: { !isBlank($0) }) ?? bytes.count
    }

    private static func restIsBlank(_ bytes: [UInt8], from index: Int) -> Bool {
        let next = skipBlank(bytes, from: index)
        return next == bytes.count || bytes[next] == hash
    }
}
