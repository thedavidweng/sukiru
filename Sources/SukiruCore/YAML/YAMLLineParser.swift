import Foundation

/// Block-level line parser: sequences, mappings and scalar dispatch.
/// Continuations live in sibling files as `LineParser` extensions.
struct LineParser {
    var lines: [String]
    var index: Int = 0
    var anchors: [String: YAMLNode] = [:]

    init(text: String) {
        // Keep empty entries (blank lines matter for block scalars); strip
        // carriage returns (CRLF input) per line. Note: `split(separator:)`
        // works on grapheme clusters where `\r\n` is ONE character, so it
        // would miss CRLF breaks — split on the scalar via Foundation.
        lines = text.components(separatedBy: "\n").map { raw in
            var line = raw
            if line.hasSuffix("\r") { line.removeLast() }
            return line
        }
    }

    /// Next non-blank, non-comment line at or after `start`, or nil.
    func peekMeaningful(from start: Int) -> LocatedLine? {
        var cursor = start
        while cursor < lines.count {
            let line = lines[cursor]
            let indent = Self.leadingSpaces(line)
            let content = String(line.dropFirst(min(indent, line.count)))
            if content.isEmpty || content.hasPrefix("#") {
                cursor += 1
                continue
            }
            return LocatedLine(line: cursor, indent: indent, content: content)
        }
        return nil
    }

    func hasContent() -> Bool {
        peekMeaningful(from: index) != nil
    }

    static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for scalar in line.unicodeScalars {
            if scalar == " " { count += 1 } else { break }
        }
        return count
    }

    func indentOf(line: Int) throws -> Int {
        let text = lines[line]
        var count = 0
        for scalar in text.unicodeScalars {
            if scalar == " " {
                count += 1
            } else if scalar == "\t" {
                throw YAMLError(tabMessage(line: line))
            } else {
                break
            }
        }
        return count
    }

    private func tabMessage(line: Int) -> String {
        "line \(line + 1): tabs are not allowed for indentation"
    }

    mutating func parseBlock(minIndent: Int) throws -> YAMLNode {
        guard let found = peekMeaningful(from: index) else {
            throw YAMLError("unexpected end of document")
        }
        guard found.indent >= minIndent else {
            throw YAMLError("line \(found.line + 1): unexpected indentation")
        }
        if Self.isSequenceItem(found.content) {
            return try parseSequence(indent: found.indent)
        }
        if mappingStart(in: found.content) != nil {
            return try parseMapping(indent: found.indent)
        }
        return try parseBlockScalarNode(first: found)
    }

    /// A `- ` item or a bare `-` (a leading `--` is a plain scalar).
    static func isSequenceItem(_ content: String) -> Bool {
        content == "-" || content.hasPrefix("- ")
    }

    /// Parses a node whose first line is a plain/quoted/flow scalar that may
    /// continue on following lines (block context).
    mutating func parseBlockScalarNode(first: LocatedLine) throws -> YAMLNode {
        index = first.line
        let parsed = try parseInline(
            first: first.content, afterLine: first.line + 1,
            keyIndent: first.indent)
        index = parsed.nextLine
        guard let value = parsed.value else {
            throw YAMLError("line \(first.line + 1): expected a value")
        }
        return value
    }
}
