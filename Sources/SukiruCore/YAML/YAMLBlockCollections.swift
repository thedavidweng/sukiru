import Foundation

extension LineParser {
    // MARK: - key detection

    /// Finds the `:` ending a mapping key: a colon followed by a space, tab,
    /// or end of content, outside of single/double quotes.
    func keyColonRange(in content: String) -> Range<String.Index>? {
        var quote = QuoteState()
        var cursor = content.startIndex
        while cursor < content.endIndex {
            let char = content[cursor]
            quote.consume(char, next: peek(content, after: cursor))
            if quote.quoted {
                cursor = content.index(after: cursor)
                continue
            }
            if char == ":" {
                let next = content.index(after: cursor)
                let isEnd = next == content.endIndex
                let isSpace = !isEnd && (content[next] == " " || content[next] == "\t")
                if isEnd || isSpace {
                    return cursor..<content.index(after: cursor)
                }
            }
            cursor = content.index(after: cursor)
        }
        return nil
    }

    private func peek(_ content: String, after cursor: String.Index) -> Character? {
        let next = content.index(after: cursor)
        guard next < content.endIndex else { return nil }
        return content[next]
    }

    /// Tracks single/double-quote state while scanning line text.
    private struct QuoteState {
        var inSingle = false
        var inDouble = false
        var escaped = false
        var quoted: Bool { inSingle || inDouble }

        mutating func consume(_ char: Character, next: Character?) {
            if escaped {
                escaped = false
                return
            }
            if inSingle {
                if char == "'" && next != "'" {
                    inSingle = false
                }
                return
            }
            if inDouble {
                if char == "\\" {
                    escaped = true
                    return
                }
                if char == "\"" {
                    inDouble = false
                }
                return
            }
            if char == "'" {
                inSingle = true
            } else if char == "\"" {
                inDouble = true
            }
        }
    }

    /// A mapping entry range, or nil for scalars/comments/flow starters.
    func mappingStart(in content: String) -> Range<String.Index>? {
        guard let first = content.first else { return nil }
        let isScalarStart = first == "'" || first == "\""
        let isFlowStart = first == "{" || first == "["
        guard !isScalarStart, !isFlowStart, first != "#" else { return nil }
        return keyColonRange(in: content)
    }

    // MARK: - sequences

    mutating func parseSequence(indent: Int) throws -> YAMLNode {
        var items: [YAMLNode] = []
        while let found = peekMeaningful(from: index) {
            guard found.indent == indent else { break }
            guard Self.isSequenceItem(found.content) else { break }
            items.append(try parseSequenceItem(found, indent: indent))
        }
        return .sequence(items)
    }

    private mutating func parseSequenceItem(
        _ found: LocatedLine, indent: Int
    ) throws -> YAMLNode {
        index = found.line
        let rest = found.content == "-" ? "" : String(found.content.dropFirst(2))
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            // Nested block on following lines.
            index = found.line + 1
            return try parseBlock(minIndent: indent + 1)
        }
        if isBlockHeader(trimmed) {
            index = found.line + 1
            return try parseBlockScalar(header: trimmed, parentIndent: indent)
        }
        if mappingStart(in: trimmed) != nil {
            // `- key: value` opens an inline mapping.
            return try parseInlineMapping(
                first: trimmed, firstLine: found.line, dashIndent: indent)
        }
        let parsed = try parseInline(
            first: trimmed, afterLine: found.line + 1, keyIndent: indent)
        switch parsed.pending {
        case .none:
            index = parsed.nextLine
            guard let value = parsed.value else {
                throw YAMLError("line \(found.line + 1): expected a value")
            }
            return value
        case .nested(let ops):
            index = parsed.nextLine
            let nested = try parseBlock(minIndent: indent + 1)
            return try apply(ops: ops, to: nested)
        }
    }

    // MARK: - mappings

    mutating func parseMapping(indent: Int) throws -> YAMLNode {
        var pairs: [YAMLPair] = []
        while let found = peekMeaningful(from: index) {
            guard found.indent == indent else { break }
            pairs.append(try parseMappingEntry(found))
        }
        return .mapping(YAMLMapping(pairs))
    }

    private mutating func parseMappingEntry(_ found: LocatedLine) throws -> YAMLPair {
        guard let colon = mappingStart(in: found.content) else {
            throw YAMLError("line \(found.line + 1): expected a mapping key")
        }
        index = found.line
        let keyNode = try mappingKey(
            String(found.content[..<colon.lowerBound]), line: found.line)
        let valueText = String(found.content[colon.upperBound...])
        let trimmed = valueText.trimmingCharacters(in: .whitespaces)
        let value = try parseMappingValue(
            trimmed, keyLine: found.line, keyIndent: found.indent)
        return YAMLPair(key: keyNode, value: value)
    }

    /// `- key: value` with further keys on following lines.
    mutating func parseInlineMapping(
        first: String, firstLine: Int, dashIndent: Int
    ) throws -> YAMLNode {
        guard let colon = mappingStart(in: first) else {
            throw YAMLError("line \(firstLine + 1): expected a mapping key")
        }
        var pairs: [YAMLPair] = []
        pairs.append(try inlinePair(first, colon: colon, line: firstLine, indent: dashIndent))
        // Further keys live deeper than the dash.
        while let found = peekMeaningful(from: index) {
            guard found.indent > dashIndent else { break }
            guard let colon = mappingStart(in: found.content) else {
                throw YAMLError("line \(found.line + 1): expected a mapping key")
            }
            index = found.line
            pairs.append(
                try inlinePair(found.content, colon: colon, line: found.line, indent: found.indent))
        }
        return .mapping(YAMLMapping(pairs))
    }

    private mutating func inlinePair(
        _ content: String, colon: Range<String.Index>, line: Int, indent: Int
    ) throws -> YAMLPair {
        index = line
        let keyNode = try mappingKey(String(content[..<colon.lowerBound]), line: line)
        let valueText = String(content[colon.upperBound...])
        let trimmed = valueText.trimmingCharacters(in: .whitespaces)
        let value = try parseMappingValue(trimmed, keyLine: line, keyIndent: indent)
        return YAMLPair(key: keyNode, value: value)
    }

    private func mappingKey(_ text: String, line: Int) throws -> YAMLNode {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw YAMLError("line \(line + 1): mapping key must not be empty")
        }
        if trimmed.hasPrefix("*") {
            throw YAMLError("line \(line + 1): aliases are not mapping keys")
        }
        var inline = InlineScanner(text: trimmed)
        let node = try inline.parseScalarFragment()
        inline.skipSpaces()
        if !inline.atEnd {
            throw YAMLError("line \(line + 1): invalid mapping key")
        }
        return node
    }

    mutating func parseMappingValue(
        _ text: String, keyLine: Int, keyIndent: Int
    ) throws -> YAMLNode {
        if isBlockHeader(text) {
            index = keyLine + 1
            return try parseBlockScalar(header: text, parentIndent: keyIndent)
        }
        if text.isEmpty || text.hasPrefix("#") {
            // Nested block or explicit null.
            let next = peekMeaningful(from: keyLine + 1)
            if let next, next.indent > keyIndent {
                index = keyLine + 1
                return try parseBlock(minIndent: keyIndent + 1)
            }
            index = keyLine + 1
            return .scalar(YAMLScalar("", tag: .null))
        }
        let parsed = try parseInline(
            first: text, afterLine: keyLine + 1, keyIndent: keyIndent)
        switch parsed.pending {
        case .none:
            index = parsed.nextLine
            guard let value = parsed.value else {
                throw YAMLError("line \(keyLine + 1): expected a value")
            }
            return value
        case .nested(let ops):
            index = parsed.nextLine
            let next = peekMeaningful(from: parsed.nextLine)
            if let next, next.indent > keyIndent {
                let nested = try parseBlock(minIndent: keyIndent + 1)
                return try apply(ops: ops, to: nested)
            }
            // Anchor/tag with no nested content: empty scalar.
            return try apply(ops: ops, to: .scalar(YAMLScalar("", tag: .null)))
        }
    }
}
