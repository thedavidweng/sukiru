import Foundation

extension InlineScanner {
    static func explicitTagStatic(from text: String) throws -> (YAMLTag, String) {
        var name = ""
        var cursor = text.index(text.startIndex, offsetBy: 2)
        while cursor < text.endIndex {
            let char = text[cursor]
            let valid = char.isLetter || char.isNumber || char == "-" || char == "_"
            guard valid else { break }
            name.append(char)
            cursor = text.index(after: cursor)
        }
        let rest = String(text[cursor...]).trimmingCharacters(in: .whitespaces)
        switch name {
        case "str": return (.str, rest)
        case "bool": return (.bool, rest)
        case "int": return (.int, rest)
        case "float": return (.float, rest)
        case "null": return (.null, rest)
        case "seq": return (.seq, rest)
        case "map": return (.map, rest)
        default: throw YAMLError("unsupported tag !!\(name)")
        }
    }

    static func applyTagStatic(tag: YAMLTag, to node: YAMLNode) throws -> YAMLNode {
        switch node {
        case .scalar(let scalar):
            if tag == .bool {
                let valid = YAMLTagResolution.boolNames.contains(scalar.string)
                if !valid {
                    throw YAMLError("invalid !!bool value: \(scalar.string)")
                }
            }
            return .scalar(YAMLScalar(scalar.string, tag: tag))
        case .mapping where tag == .map, .sequence where tag == .seq:
            return node
        default:
            throw YAMLError("mismatched explicit tag \(tag.rawValue)")
        }
    }

    /// Parses a flow mapping/sequence at the cursor.
    mutating func parseFlow() throws -> YAMLNode {
        guard !atEnd else { throw YAMLError("expected a flow collection") }
        if text[index] == "[" {
            return try parseFlowSequence()
        }
        if text[index] == "{" {
            return try parseFlowMapping()
        }
        throw YAMLError("expected a flow collection")
    }

    private mutating func parseFlowSequence() throws -> YAMLNode {
        index = text.index(after: index)
        var items: [YAMLNode] = []
        skipSpaces()
        if consumeIf("]") {
            return .sequence(items)
        }
        while true {
            skipSpaces()
            items.append(try parseFlowValue())
            skipSpaces()
            guard !atEnd else { throw YAMLError("unterminated flow sequence") }
            if consumeIf(",") {
                continue
            }
            if consumeIf("]") {
                return .sequence(items)
            }
            throw YAMLError("expected `,` or `]` in flow sequence")
        }
    }

    private mutating func parseFlowMapping() throws -> YAMLNode {
        index = text.index(after: index)
        var pairs: [YAMLPair] = []
        skipSpaces()
        if consumeIf("}") {
            return .mapping(YAMLMapping(pairs))
        }
        while true {
            skipSpaces()
            let quotedKey = !atEnd && (text[index] == "\"" || text[index] == "'")
            let key = try parseFlowValue()
            skipSpaces()
            guard !atEnd, text[index] == ":" else {
                throw YAMLError("expected `:` in flow mapping")
            }
            if !quotedKey {
                try checkColonSeparation()
            }
            index = text.index(after: index)
            skipSpaces()
            let value = try parseFlowValue()
            pairs.append(YAMLPair(key: key, value: value))
            skipSpaces()
            guard !atEnd else { throw YAMLError("unterminated flow mapping") }
            if consumeIf(",") {
                continue
            }
            if consumeIf("}") {
                return .mapping(YAMLMapping(pairs))
            }
            throw YAMLError("expected `,` or `}` in flow mapping")
        }
    }

    /// Consumes `char` at the cursor when present.
    private mutating func consumeIf(_ char: Character) -> Bool {
        guard !atEnd, text[index] == char else { return false }
        index = text.index(after: index)
        return true
    }

    /// Plain flow keys require separation after `:`; quoted keys permit JSON adjacency.
    private func checkColonSeparation() throws {
        let afterColon = text.index(after: index)
        guard afterColon < text.endIndex else { return }
        let next = text[afterColon]
        let separated = next == " " || next == "\t" || next == "\n"
        let isBracket = next == "," || next == "}" || next == "]"
        if !separated, !isBracket {
            throw YAMLError("expected separation after `:` in flow mapping")
        }
    }

    mutating func parseFlowValue() throws -> YAMLNode {
        skipSpaces()
        guard !atEnd else { throw YAMLError("expected a value") }
        let char = text[index]
        if char == "'" || char == "\"" {
            guard let node = try parseQuoted(balanceRequired: true) else {
                throw YAMLError("unterminated quoted scalar")
            }
            return node
        }
        if char == "[" || char == "{" {
            return try parseFlow()
        }
        if char == "&" || char == "*" || char == "!" {
            return try parseFlowPrefixed()
        }
        if char == "|" || char == ">" {
            throw YAMLError("unsupported flow construct starting with `\(char)`")
        }
        return try parseFlowPlain()
    }

    /// Anchor, alias or explicit tag inside flow.
    private mutating func parseFlowPrefixed() throws -> YAMLNode {
        let char = text[index]
        if char == "*" {
            return .scalar(YAMLScalar(try flowName(), tag: YAMLTag("__alias__")))
        }
        if char == "&" {
            let name = try flowName()
            let node = try parseFlowValue()
            anchorValues[name] = node
            return node
        }
        // `!!tag` (or lone `!` = non-specific, resolve normally).
        if remainder.hasPrefix("!!") {
            let (tag, rest) = try Self.explicitTagStatic(from: remainder)
            advancePast(text: text, remainder: remainder, rest: rest)
            skipSpaces()
            if !atEnd, text[index] == "&" {
                let name = try flowName()
                skipSpaces()
                let node = try parseFlowValue()
                let tagged = try Self.applyTagStatic(tag: tag, to: node)
                anchorValues[name] = tagged
                return tagged
            }
            let node = try parseFlowValue()
            return try Self.applyTagStatic(tag: tag, to: node)
        }
        index = text.index(after: index)
        return try parseFlowValue()
    }

    /// Reads an anchor/alias name at the cursor and advances past it.
    private mutating func flowName() throws -> String {
        // Caller guarantees cursor is on `&` or `*`.
        var name = ""
        var cursor = text.index(after: index)
        while cursor < text.endIndex {
            let char = text[cursor]
            let valid = char.isLetter || char.isNumber || char == "_" || char == "-"
            guard valid else { break }
            name.append(char)
            cursor = text.index(after: cursor)
        }
        guard !name.isEmpty else {
            throw YAMLError("invalid anchor or alias")
        }
        index = cursor
        return name
    }

    /// The character after `cursor`, if any.
    private func peekNext(after cursor: String.Index) -> Character? {
        let next = text.index(after: cursor)
        guard next < text.endIndex else { return nil }
        return text[next]
    }

    /// Repositions past a tag token given the pre/post remainders.
    private mutating func advancePast(text: String, remainder: String, rest: String) {
        let consumed = remainder.count - rest.count
        index = text.index(index, offsetBy: consumed)
    }

    /// Plain scalar: up to `,`, `]`, `}`, ` #` comment, or `: ` boundary.
    private mutating func parseFlowPlain() throws -> YAMLNode {
        var raw = ""
        var cursor = index
        var quote = FlowQuoteState()
        while cursor < text.endIndex {
            let char = text[cursor]
            let next = peekNext(after: cursor)
            quote.consume(char, next: next)
            if quote.quoted {
                raw.append(char)
                cursor = text.index(after: cursor)
                continue
            }
            if char == "," || char == "[" || char == "]" || char == "{" || char == "}" {
                break
            }
            if char == ":" {
                let next = text.index(after: cursor)
                let isEnd = next == text.endIndex
                let follows = !isEnd && (text[next] == " " || text[next] == "\t")
                let closes = !isEnd && (text[next] == "\n" || text[next] == ",")
                let shuts = !isEnd && (text[next] == "}" || text[next] == "]")
                if isEnd || follows || closes || shuts {
                    break
                }
                raw.append(char)
            } else if char == "#", !raw.isEmpty {
                let last = raw.last!
                if last == " " || last == "\t" {
                    break
                }
                raw.append(char)
            } else if char == "\n" {
                raw.append(" ")
            } else {
                raw.append(char)
            }
            cursor = text.index(after: cursor)
        }
        index = cursor
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let tag = YAMLTagResolution.resolve(plain: trimmed)
        return .scalar(YAMLScalar(trimmed, tag: tag))
    }

    /// Quote tracking for flow plain scalars.
    private struct FlowQuoteState {
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
}
