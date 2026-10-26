import Foundation

/// Member-level JSON edits. Each edit replaces or inserts one token range and leaves every
/// other byte as it was; inserted text follows the document's detected indentation.
/// An ordered JSON value: key order is what the user reads in the file.
indirect enum HookEditValue: Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case raw(String)
    case object([(String, HookEditValue)])
    case array([HookEditValue])
}

extension HookJSONDocument {
    enum Step {
        case key(String)
        case index(Int)
    }

    /// The indentation unit (nil for single-line documents) and key/value spacing.
    struct Style {
        let unit: String?
        let colon: String
        var separator: String { colon == ":" ? "," : ", " }

        init(bytes: [UInt8], root: Range<Int>) {
            let text = String(bytes: bytes, encoding: .utf8) ?? ""
            let spaced = text.contains("\": ")
            let tight = text.range(of: #"":[^ ]"#, options: .regularExpression) != nil
            colon = tight && !spaced ? ":" : ": "
            guard bytes[root].contains(10) else {
                unit = nil
                return
            }
            var widths: [Int] = []
            for line in text.split(separator: "\n").dropFirst() {
                let leading = line.prefix { $0 == " " || $0 == "\t" }
                guard leading.count < line.count else { continue }
                if leading.first == "\t" {
                    unit = "\t"
                    return
                }
                if !leading.isEmpty { widths.append(leading.count) }
            }
            unit = String(repeating: " ", count: widths.min() ?? 2)
        }
    }

    /// Content for a source file that does not exist yet.
    static let emptyDocument = Data("{\n}\n".utf8)

    var style: Style { Style(bytes: bytes, root: root.range) }

    func node(at path: [Step]) -> Node? {
        var node = root
        for step in path {
            switch step {
            case .key(let key):
                guard node.isObject, let next = node.member(key) else { return nil }
                node = next
            case .index(let index):
                guard node.isArray, node.members.indices.contains(index) else { return nil }
                node = node.members[index].node
            }
        }
        return node
    }

    /// Appends one matcher group to `hooks.<event>`, creating missing containers.
    func appendingGroup(event: String, group: HookEditValue) throws -> Data {
        guard root.isObject else { throw HookError("Expected a JSON object at the top level") }
        guard let hooks = root.member("hooks") else {
            return try inserting(.object([(event, .array([group]))]), key: "hooks", into: root)
        }
        guard hooks.isObject else { throw HookError("Expected hooks object") }
        guard let groups = hooks.member(event) else {
            return try inserting(.array([group]), key: event, into: hooks)
        }
        guard groups.isArray else { throw HookError("Expected matcher groups for " + event) }
        return try inserting(group, key: nil, into: groups)
    }

    /// Sets, inserts, or (for nil) removes one object member at `path`.
    func setting(
        _ key: String, to value: HookEditValue?, at path: [Step], first: Bool = false
    ) throws -> Data {
        guard let node = self.node(at: path), node.isObject else {
            throw HookError("Hook structure changed; rescan and replan")
        }
        guard let index = node.members.firstIndex(where: { $0.key == key }) else {
            guard let value else { return Data(bytes) }
            return try inserting(value, key: key, into: node, first: first)
        }
        let member = node.members[index]
        guard let value else {
            return try replacing(removals(in: node, indices: [index]).map { ($0, "") })
        }
        let indent = lineIndent(at: member.range.lowerBound)
        let text = render(value, indent: indent, compact: !startsLine(member.range.lowerBound))
        return try replacing([(member.node.range, text)])
    }

    private func inserting(
        _ value: HookEditValue, key: String?, into node: Node, first: Bool = false
    ) throws -> Data {
        let style = self.style
        let prefix = key.map { encode($0) + style.colon } ?? ""
        let open = node.range.lowerBound
        guard let anchor = first ? node.members.first : node.members.last else {
            let interior = open + 1..<node.range.upperBound - 1
            guard let unit = style.unit else {
                return try replacing([(interior, prefix + render(value, indent: "", compact: true))]
                )
            }
            let outer = lineIndent(at: open)
            let text = prefix + render(value, indent: outer + unit, compact: false)
            return try replacing([(interior, "\n" + outer + unit + text + "\n" + outer)])
        }
        let inline = style.unit == nil || !startsLine(anchor.range.lowerBound)
        let indent = lineIndent(at: anchor.range.lowerBound)
        let text = prefix + render(value, indent: indent, compact: inline)
        if first {
            let tail = inline ? style.separator : ",\n" + indent
            return try replacing([(anchor.range.lowerBound..<anchor.range.lowerBound, text + tail)])
        }
        let head = inline ? style.separator : ",\n" + indent
        return try replacing([(anchor.range.upperBound..<anchor.range.upperBound, head + text)])
    }

    private func replacing(_ edits: [(Range<Int>, String)]) throws -> Data {
        var result = bytes
        for (range, text) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            result.replaceSubrange(range, with: Array(text.utf8))
        }
        _ = try HookJSONDocument(Data(result))
        return Data(result)
    }

    private func lineStart(_ offset: Int) -> Int {
        var start = offset
        while start > 0 && bytes[start - 1] != 10 { start -= 1 }
        return start
    }

    private func lineIndent(at offset: Int) -> String {
        let start = lineStart(offset)
        var end = start
        while end < offset && (bytes[end] == 32 || bytes[end] == 9) { end += 1 }
        return String(bytes: bytes[start..<end], encoding: .utf8) ?? ""
    }

    private func startsLine(_ offset: Int) -> Bool {
        bytes[lineStart(offset)..<offset].allSatisfy { $0 == 32 || $0 == 9 }
    }

    private func encode(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = (try? encoder.encode(text)) ?? Data("\"\"".utf8)
        return String(bytes: data, encoding: .utf8) ?? "\"\""
    }

    private func render(_ value: HookEditValue, indent: String, compact: Bool) -> String {
        let style = self.style
        let unit = compact ? nil : style.unit
        func container(_ items: [String], _ open: String, _ close: String) -> String {
            guard !items.isEmpty else { return open + close }
            guard let unit else { return open + items.joined(separator: style.separator) + close }
            return open + "\n" + items.map { indent + unit + $0 }.joined(separator: ",\n") + "\n"
                + indent + close
        }
        let inner = indent + (unit ?? "")
        switch value {
        case .string(let text): return encode(text)
        case .int(let number): return String(number)
        case .bool(let flag): return String(flag)
        case .raw(let text): return text
        case .object(let members):
            let items = members.map {
                encode($0.0) + style.colon + render($0.1, indent: inner, compact: compact)
            }
            return container(items, "{", "}")
        case .array(let values):
            return container(
                values.map { render($0, indent: inner, compact: compact) }, "[", "]")
        }
    }
}

extension HookEditValue {
    /// Keeps a scanned field the edit form does not manage.
    init(_ value: JSONValue) {
        switch value {
        case .string(let text): self = .string(text)
        case .int(let number): self = .int(number)
        case .bool(let flag): self = .bool(flag)
        case .double(let number): self = .raw(String(describing: number))
        case .null: self = .raw("null")
        case .array(let values): self = .array(values.map(Self.init))
        case .object(let fields):
            self = .object(fields.keys.sorted().map { ($0, Self(fields[$0]!)) })
        }
    }
}
