import Foundation

extension LineParser {
    func isBlockHeader(_ text: String) -> Bool {
        guard let first = text.first, first == "|" || first == ">" else {
            return false
        }
        var seenChomping = false
        var seenIndent = false
        var cursor = text.index(after: text.startIndex)
        while cursor < text.endIndex {
            let char = text[cursor]
            if char == "-" || char == "+" {
                guard !seenChomping else { return false }
                seenChomping = true
            } else if char >= "1", char <= "9" {
                guard !seenIndent else { return false }
                seenIndent = true
            } else if char == " " || char == "\t" {
                break
            } else {
                return false
            }
            cursor = text.index(after: cursor)
        }
        let rest = String(text[cursor...]).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty || rest.hasPrefix("#")
    }

    mutating func parseBlockScalar(header: String, parentIndent: Int) throws -> YAMLNode {
        let style = header.first!
        var chomping: Character = "c"  // clip
        var explicitIndent: Int?
        for char in header.dropFirst() {
            if char == " " || char == "\t" || char == "#" { break }
            if char == "-" || char == "+" {
                chomping = char
            } else if let digit = char.wholeNumberValue {
                explicitIndent = digit
            } else {
                throw YAMLError("invalid block scalar header: \(header)")
            }
        }
        // Collect candidate content lines (blank lines included); the
        // dedicated pass below decides where the scalar ends.
        var cursor = index
        var rawLines: [String] = []
        while cursor < lines.count {
            rawLines.append(lines[cursor])
            cursor += 1
        }
        let job = ScalarJob(
            rawLines: rawLines, startLine: index, style: style,
            chomping: chomping, explicitIndent: explicitIndent,
            parentIndent: parentIndent)
        return try parseBlockScalarLines(job: job)
    }

    /// Parses block scalar content from raw lines; consumes only the lines
    /// belonging to the scalar.
    mutating func parseBlockScalarLines(job: ScalarJob) throws -> YAMLNode {
        guard let contentIndent = try scalarIndent(job: job),
            contentIndent > job.parentIndent
        else {
            // No indented content: empty scalar, consume nothing.
            return .scalar(YAMLScalar("", tag: .str))
        }
        var content: [String] = []
        var consumed = 0
        for line in job.rawLines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                content.append("")
                consumed += 1
                continue
            }
            let indent = try indentOf(line: job.startLine + consumed)
            guard indent >= contentIndent else { break }
            let stripped = String(line.dropFirst(min(contentIndent, line.count)))
            content.append(stripped)
            consumed += 1
        }
        index = job.startLine + consumed
        // Trailing blanks: dropped for strip/clip, kept for keep.
        var trailingBlanks = 0
        while !content.isEmpty {
            let isBlank = content.last!.trimmingCharacters(in: .whitespaces).isEmpty
            guard isBlank else { break }
            content.removeLast()
            trailingBlanks += 1
        }
        if job.style == "|" {
            return literalNode(
                content: content, chomping: job.chomping, blanks: trailingBlanks)
        }
        return foldedNode(
            content: content, chomping: job.chomping, blanks: trailingBlanks)
    }

    /// A block scalar parse job.
    struct ScalarJob {
        var rawLines: [String]
        var startLine: Int
        var style: Character
        var chomping: Character
        var explicitIndent: Int?
        var parentIndent: Int
    }

    /// Content indent, or nil when there is no content.
    private func scalarIndent(job: ScalarJob) throws -> Int? {
        if let explicit = job.explicitIndent {
            return job.parentIndent + explicit
        }
        for (offset, line) in job.rawLines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            return try indentOf(line: job.startLine + offset)
        }
        return nil
    }

    private func literalNode(
        content: [String], chomping: Character, blanks: Int
    ) -> YAMLNode {
        let text = content.joined(separator: "\n")
        switch chomping {
        case "-":
            return .scalar(YAMLScalar(text, tag: .str))
        case "+":
            if content.isEmpty && blanks == 0 {
                return .scalar(YAMLScalar("", tag: .str))
            }
            let kept = text + "\n" + String(repeating: "\n", count: blanks)
            return .scalar(YAMLScalar(kept, tag: .str))
        default:
            if content.isEmpty {
                return .scalar(YAMLScalar("", tag: .str))
            }
            return .scalar(YAMLScalar(text + "\n", tag: .str))
        }
    }

    private func foldedNode(
        content: [String], chomping: Character, blanks: Int
    ) -> YAMLNode {
        let folded = foldLines(content)
        switch chomping {
        case "-":
            return .scalar(YAMLScalar(folded, tag: .str))
        case "+":
            if folded.isEmpty && blanks == 0 {
                return .scalar(YAMLScalar("", tag: .str))
            }
            let kept = folded + "\n" + String(repeating: "\n", count: blanks)
            return .scalar(YAMLScalar(kept, tag: .str))
        default:
            if folded.isEmpty {
                return .scalar(YAMLScalar("", tag: .str))
            }
            return .scalar(YAMLScalar(folded + "\n", tag: .str))
        }
    }

    /// Folds content lines: single breaks become spaces, blank and
    /// more-indented lines keep their breaks.
    private func foldLines(_ content: [String]) -> String {
        var folded = ""
        var cursor = 0
        while cursor < content.count {
            let line = content[cursor]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                folded += "\n"
                cursor += 1
                continue
            }
            if Self.isMoreIndented(line) {
                folded = Self.appendVerbatim(folded, line: line)
                cursor += 1
                cursor = Self.consumeVerbatim(content, folded: &folded, from: cursor)
                continue
            }
            if folded.isEmpty || folded.hasSuffix("\n") {
                folded += line
            } else {
                folded += " " + line
            }
            cursor += 1
        }
        return folded
    }

    private static func isMoreIndented(_ line: String) -> Bool {
        line.hasPrefix(" ") || line.hasPrefix("\t")
    }

    private static func appendVerbatim(_ folded: String, line: String) -> String {
        var result = folded
        if !result.isEmpty, !result.hasSuffix("\n") {
            result += "\n"
        }
        result += line + "\n"
        return result
    }

    /// Appends following more-indented lines verbatim; returns the cursor.
    private static func consumeVerbatim(
        _ content: [String], folded: inout String, from start: Int
    ) -> Int {
        var cursor = start
        while cursor < content.count {
            let next = content[cursor]
            if next.trimmingCharacters(in: .whitespaces).isEmpty { break }
            guard isMoreIndented(next) else { break }
            folded += next + "\n"
            cursor += 1
        }
        return cursor
    }
}
