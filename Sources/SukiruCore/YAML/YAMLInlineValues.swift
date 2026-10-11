import Foundation

extension LineParser {
    /// Parses an inline value starting with `first` (rest of the current
    /// line); may consume following lines for multi-line quoted/flow scalars
    /// or plain continuations deeper than `keyIndent`.
    mutating func parseInline(
        first: String, afterLine: Int, keyIndent: Int
    ) throws -> InlineResult {
        let prefix = try stripPrefixes(first, afterLine: afterLine)
        if let aliased = prefix.alias {
            return aliased
        }
        let trimmed = prefix.text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") {
            let pending = InlineResult(
                value: nil, pending: .nested(prefix.ops),
                nextLine: prefix.nextLine)
            return pending
        }
        if trimmed.hasPrefix("|") || trimmed.hasPrefix(">") {
            throw YAMLError("line \(prefix.nextLine): block scalar not allowed here")
        }
        guard let firstChar = trimmed.first else {
            throw YAMLError("line \(prefix.nextLine): expected a value")
        }
        let isQuoted = firstChar == "'" || firstChar == "\""
        if isQuoted || firstChar == "[" || firstChar == "{" {
            let consumed = try parseMultilineScalar(
                first: trimmed, fromLine: prefix.nextLine,
                startLine: afterLine)
            let tagged = try apply(ops: prefix.ops, to: consumed.node)
            return InlineResult(
                value: tagged, pending: .none, nextLine: consumed.nextLine)
        }
        return try parsePlain(
            trimmed, ops: prefix.ops, keyIndent: keyIndent,
            nextLine: prefix.nextLine)
    }

    /// An alias target or the remaining text after `&`/`!!` prefixes.
    private struct Prefix {
        var alias: InlineResult?
        var text: String
        var ops: PendingOps
        var nextLine: Int
    }

    private mutating func stripPrefixes(
        _ first: String, afterLine: Int
    ) throws -> Prefix {
        var ops = PendingOps()
        var text = first
        let nextLine = afterLine
        while true {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("&") {
                let name = Self.anchorName(from: trimmed)
                ops.anchor = name
                text = String(trimmed.dropFirst(name.count + 1))
                continue
            }
            if trimmed.hasPrefix("!!") {
                let (tag, rest) = try explicitTag(from: trimmed, line: nextLine)
                ops.tag = tag
                text = rest
                continue
            }
            if trimmed == "!" {
                text = ""
                continue
            }
            if trimmed.hasPrefix("*") {
                return Prefix(
                    alias: try aliasResult(trimmed, line: nextLine),
                    text: "", ops: ops, nextLine: nextLine)
            }
            return Prefix(alias: nil, text: text, ops: ops, nextLine: nextLine)
        }
    }

    private func aliasResult(_ trimmed: String, line: Int) throws -> InlineResult {
        let name = Self.anchorName(from: trimmed)
        let rest = String(trimmed.dropFirst(name.count + 1))
        let trailing = rest.trimmingCharacters(in: .whitespaces)
        if !trailing.isEmpty, !trailing.hasPrefix("#") {
            throw YAMLError("line \(line): unexpected text after alias")
        }
        guard let target = anchors[name] else {
            throw YAMLError("line \(line): undefined alias *\(name)")
        }
        return InlineResult(value: target, pending: .none, nextLine: line)
    }

    /// Plain scalar: strip trailing comment, fold continuations.
    private mutating func parsePlain(
        _ trimmed: String, ops: PendingOps, keyIndent: Int, nextLine: Int
    ) throws -> InlineResult {
        var scalarText = stripComment(trimmed)
        var cursor = nextLine
        while let found = peekMeaningful(from: cursor) {
            let continues = found.indent > keyIndent
            let isItem = Self.isSequenceItem(found.content)
            let isKey = mappingStart(in: found.content) != nil
            guard continues, !isItem, !isKey else { break }
            scalarText += " " + stripComment(found.content)
            cursor = found.line + 1
        }
        let node = plainNode(scalarText)
        let value = try apply(ops: ops, to: node)
        return InlineResult(value: value, pending: .none, nextLine: cursor)
    }

    mutating func apply(ops: PendingOps, to node: YAMLNode) throws -> YAMLNode {
        var result = node
        if let tag = ops.tag {
            result = try applyTag(tag, to: result)
        }
        if let anchor = ops.anchor {
            anchors[anchor] = result
        }
        return result
    }

    private func applyTag(_ tag: YAMLTag, to node: YAMLNode) throws -> YAMLNode {
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

    /// Parses a quoted or flow scalar that may span lines. Flow-level
    /// anchors merge into `anchors` so aliases resolve.
    mutating func parseMultilineScalar(
        first: String, fromLine: Int, startLine: Int
    ) throws -> ScalarConsume {
        guard let quote = first.first else {
            throw YAMLError("line \(fromLine): expected a value")
        }
        if quote == "'" || quote == "\"" {
            return try parseMultilineQuoted(
                first: first, fromLine: fromLine, startLine: startLine)
        }
        return try parseMultilineFlow(
            first: first, fromLine: fromLine, startLine: startLine)
    }

    private mutating func parseMultilineQuoted(
        first: String, fromLine: Int, startLine: Int
    ) throws -> ScalarConsume {
        var buffer = first
        var cursor = startLine
        while true {
            var scanner = InlineScanner(text: buffer)
            if let node = try scanner.parseQuoted(balanceRequired: false) {
                scanner.skipSpaces()
                let rest = scanner.remainder.trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty, !rest.hasPrefix("#") {
                    throw YAMLError("line \(fromLine): unexpected text after scalar")
                }
                return ScalarConsume(node: node, nextLine: cursor)
            }
            // Unterminated: fold the next line in.
            guard cursor < lines.count else {
                throw YAMLError("line \(fromLine): unterminated quoted scalar")
            }
            let folded = lines[cursor].trimmingCharacters(in: .whitespaces)
            buffer += " " + folded
            cursor += 1
        }
    }

    private mutating func parseMultilineFlow(
        first: String, fromLine: Int, startLine: Int
    ) throws -> ScalarConsume {
        var buffer = first
        var cursor = startLine
        while Self.bracketDepth(of: buffer) > 0 {
            guard cursor < lines.count else {
                throw YAMLError("line \(fromLine): unterminated flow collection")
            }
            buffer += "\n" + lines[cursor]
            cursor += 1
        }
        var scanner = InlineScanner(text: buffer)
        let node = try scanner.parseFlow()
        scanner.skipSpaces()
        let rest = scanner.remainder.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty, !rest.hasPrefix("#") {
            throw YAMLError("line \(fromLine): unexpected text after scalar")
        }
        for (name, value) in scanner.anchorValues {
            anchors[name] = value
        }
        let resolved = try resolveAliases(in: node, line: fromLine)
        return ScalarConsume(node: resolved, nextLine: cursor)
    }

    /// Bracket depth ignoring quoted sections (multiline gate).
    static func bracketDepth(of text: String) -> Int {
        var tracker = BracketTracker()
        for char in text {
            tracker.feed(char)
        }
        return tracker.depth
    }

    /// Character-level bracket tracking with quote awareness.
    private struct BracketTracker {
        var depth = 0
        var inSingle = false
        var inDouble = false
        var escaped = false

        mutating func feed(_ char: Character) {
            if escaped {
                escaped = false
                return
            }
            if inSingle || inDouble {
                feedQuoted(char)
                return
            }
            switch char {
            case "'": inSingle = true
            case "\"": inDouble = true
            case "{", "[": depth += 1
            case "}", "]": depth -= 1
            default: break
            }
        }

        private mutating func feedQuoted(_ char: Character) {
            if inSingle {
                if char == "'" { inSingle = false }
                return
            }
            if char == "\\" {
                escaped = true
            } else if char == "\"" {
                inDouble = false
            }
        }
    }

    func resolveAliases(in node: YAMLNode, line: Int) throws -> YAMLNode {
        switch node {
        case .scalar(let scalar):
            if scalar.tag.rawValue == "__alias__" {
                guard let target = anchors[scalar.string] else {
                    throw YAMLError("line \(line): undefined alias *\(scalar.string)")
                }
                return target
            }
            return node
        case .sequence(let items):
            let resolved = try items.map { try resolveAliases(in: $0, line: line) }
            return .sequence(resolved)
        case .mapping(let mapping):
            let pairs = try mapping.pairs.map { pair in
                YAMLPair(
                    key: try resolveAliases(in: pair.key, line: line),
                    value: try resolveAliases(in: pair.value, line: line))
            }
            return .mapping(YAMLMapping(pairs))
        }
    }

    static func anchorName(from text: String) -> String {
        var name = ""
        for char in text.dropFirst() {
            let valid = char.isLetter || char.isNumber || char == "_" || char == "-"
            guard valid else { break }
            name.append(char)
        }
        return name
    }

    func explicitTag(from text: String, line: Int) throws -> (YAMLTag, String) {
        // Text starts with `!!`.
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
        default: throw YAMLError("line \(line): unsupported tag !!\(name)")
        }
    }

    func plainNode(_ text: String) -> YAMLNode {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return .scalar(YAMLScalar(trimmed, tag: YAMLTagResolution.resolve(plain: trimmed)))
    }

    /// Strips a trailing ` #comment` (hash preceded by separation space).
    func stripComment(_ text: String) -> String {
        var state = CommentScan()
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let char = text[cursor]
            state.consume(char, next: peekNextChar(text, after: cursor))
            if !state.quoted && char == "#" && state.separated {
                let head = String(text[..<cursor])
                return head.trimmingCharacters(in: .whitespaces)
            }
            let isSpace = char == " " || char == "\t"
            state.separated = isSpace && !state.quoted
            cursor = text.index(after: cursor)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private func peekNextChar(_ text: String, after cursor: String.Index) -> Character? {
        let next = text.index(after: cursor)
        guard next < text.endIndex else { return nil }
        return text[next]
    }

    /// Quote/escape tracking for comment scans.
    private struct CommentScan {
        var inSingle = false
        var inDouble = false
        var escaped = false
        var separated = false
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
