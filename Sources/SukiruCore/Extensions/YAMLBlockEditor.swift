import Foundation

/// Line edits of block-style YAML mappings and lists (Hermes \`config.yaml\`, oh-my-pi
/// \`config.yml\`). Every edit is checked by parsing the result and comparing it with the
/// intended change; flow collections, anchors, and other forms are refused.
struct YAMLBlockEditor {
    private(set) var lines: [String]
    private let original: JSONValue

    init(_ text: String) throws {
        lines = text.components(separatedBy: "\n")
        original = try YAMLSubset.jsonValue(yaml: text)
    }

    var text: String { lines.joined(separator: "\n") }

    /// Adds or removes one string item of the list at \`keys\`, creating missing keys.
    mutating func setItem(_ item: String, present: Bool, at keys: [String]) throws {
        var items = (original.at(keys)?.arrayValue ?? []).compactMap(\.stringValue)
        guard items.contains(item) != present else { return }
        if present {
            try insertItem(item, at: keys)
            items.append(item)
        } else {
            try removeItem(item, at: keys)
            items.removeAll { $0 == item }
        }
        try verify(original.setting(keys, to: .array(items.map(JSONValue.string))))
    }

    /// Sets the scalar at \`keys\` inside an existing mapping.
    mutating func setScalar(_ value: String, json: JSONValue, at keys: [String]) throws {
        if let found = locate(keys) {
            lines[found.line] =
                String(repeating: " ", count: found.indent) + found.key + ": " + value
        } else {
            guard let parent = locate(Array(keys.dropLast())) else { throw refuse(keys) }
            let indent = childIndent(of: parent)
            lines.insert(
                String(repeating: " ", count: indent) + Self.key(keys.last!) + ": " + value,
                at: parent.line + 1)
        }
        try verify(original.setting(keys, to: json))
    }

    /// Removes the entry at \`keys\` with everything nested under it.
    mutating func remove(at keys: [String]) throws {
        guard let found = locate(keys) else { throw refuse(keys) }
        lines.removeSubrange(found.line..<blockEnd(found))
        try verify(original.setting(keys, to: nil))
    }

    // MARK: - lines

    private struct Entry {
        let key: String
        /// The key as written, quotes included.
        let raw: String
        let value: String
    }

    private struct Found {
        let line: Int
        let indent: Int
        let key: String
        let value: String
    }

    private func locate(_ keys: [String]) -> Found? {
        var range = 0..<lines.count
        var found: Found?
        for key in keys {
            let children = range.filter { Self.content(lines[$0]) != nil }
            guard let first = children.first else { return nil }
            let indent = Self.indent(lines[first])
            guard
                let line = children.first(where: {
                    Self.indent(lines[$0]) == indent && Self.entry(lines[$0])?.key == key
                }), let entry = Self.entry(lines[line])
            else { return nil }
            let next = Found(line: line, indent: indent, key: entry.raw, value: entry.value)
            found = next
            range = line + 1..<blockEnd(next)
        }
        return found
    }

    /// The first line after the entry's nested block; a list may sit at the key's indent.
    private func blockEnd(_ found: Found) -> Int {
        var index = found.line + 1
        while index < lines.count {
            if let content = Self.content(lines[index]) {
                let indent = Self.indent(lines[index])
                if indent < found.indent || (indent == found.indent && !content.hasPrefix("- ")) {
                    break
                }
            }
            index += 1
        }
        return index
    }

    private func childIndent(of found: Found) -> Int {
        (found.line + 1..<blockEnd(found)).first { Self.content(lines[$0]) != nil }
            .map { Self.indent(lines[$0]) } ?? found.indent + 2
    }

    private mutating func insertItem(_ item: String, at keys: [String]) throws {
        let rendered = Self.scalar(item)
        guard let found = locate(keys) else {
            var prefix = keys
            var created: [String] = []
            while !prefix.isEmpty, locate(prefix) == nil {
                created.insert(prefix.removeLast(), at: 0)
            }
            let parent = prefix.isEmpty ? nil : locate(prefix)
            guard parent.map({ $0.value.isEmpty }) ?? true else { throw refuse(keys) }
            var indent = parent.map(childIndent) ?? 0
            var block: [String] = []
            for key in created {
                block.append(String(repeating: " ", count: indent) + Self.key(key) + ":")
                indent += 2
            }
            block.append(String(repeating: " ", count: indent) + "- " + rendered)
            var insertion = parent.map(blockEnd) ?? lines.count
            if parent == nil, lines.last == "" { insertion = lines.count - 1 }
            lines.insert(contentsOf: block, at: insertion)
            return
        }
        let itemLines = (found.line + 1..<blockEnd(found)).filter {
            Self.content(lines[$0])?.hasPrefix("- ") == true
        }
        if found.value == "[]" {
            lines[found.line] = String(repeating: " ", count: found.indent) + found.key + ":"
        } else if !found.value.isEmpty || itemLines.isEmpty {
            throw refuse(keys)
        }
        let indent = itemLines.first.map { Self.indent(lines[$0]) } ?? found.indent + 2
        lines.insert(
            String(repeating: " ", count: indent) + "- " + rendered,
            at: (itemLines.last ?? found.line) + 1)
    }

    private mutating func removeItem(_ item: String, at keys: [String]) throws {
        guard let found = locate(keys) else { throw refuse(keys) }
        let itemLines = (found.line + 1..<blockEnd(found)).filter {
            Self.content(lines[$0])?.hasPrefix("- ") == true
        }
        guard
            let line = itemLines.first(where: {
                Self.unquoted(String(Self.content(lines[$0])!.dropFirst(2))) == item
            })
        else { throw refuse(keys) }
        lines.remove(at: line)
        if itemLines.count == 1 {
            lines[found.line] = String(repeating: " ", count: found.indent) + found.key + ": []"
        }
    }

    private func verify(_ expected: JSONValue) throws {
        guard (try? YAMLSubset.jsonValue(yaml: text)) == expected else {
            throw HookError("The edited YAML would not read back as intended")
        }
    }

    private func refuse(_ keys: [String]) -> HookError {
        HookError("Unsupported YAML layout at " + keys.joined(separator: "."))
    }

    // MARK: - tokens

    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    /// The line without comment and surrounding spaces; nil when nothing remains.
    private static func content(_ line: String) -> String? {
        let text = HookTOMLDocument.withoutComment(line).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func entry(_ line: String) -> Entry? {
        guard let content = content(line), !content.hasPrefix("- ") else { return nil }
        var raw = content.prefix { $0 != ":" }
        if let quote = content.first, quote == "\"" || quote == "'" {
            guard let close = content.dropFirst().firstIndex(of: quote) else { return nil }
            raw = content[...close]
        }
        let rest = content.dropFirst(raw.count)
        guard rest.hasPrefix(":") else { return nil }
        return Entry(
            key: unquoted(String(raw)), raw: String(raw),
            value: rest.dropFirst().trimmingCharacters(in: .whitespaces))
    }

    private static func unquoted(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == "\"" || first == "'",
            text.last == first
        else { return text }
        guard first == "\"" else { return String(text.dropFirst().dropLast()) }
        return (try? JSONDecoder().decode(String.self, from: Data(text.utf8)))
            ?? String(text.dropFirst().dropLast())
    }

    private static func scalar(_ text: String) -> String {
        let plain = text.range(
            of: #"^[A-Za-z0-9_][A-Za-z0-9_./@+:-]*$"#, options: .regularExpression)
        guard
            plain == nil || text.contains(": ")
                || ["true", "false", "null", "yes", "no", "~"].contains(text) || Double(text) != nil
        else { return text }
        let data = (try? JSONEncoder().encode(text)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? text
    }

    private static func key(_ text: String) -> String { scalar(text) }
}

extension JSONValue {
    func at(_ keys: [String]) -> JSONValue? {
        keys.reduce(Optional(self)) { $0?[$1] }
    }

    /// The tree with the member at \`keys\` replaced, or removed for nil; missing parents are
    /// created as objects.
    func setting(_ keys: [String], to value: JSONValue?) -> JSONValue {
        guard let key = keys.first else { return value ?? .null }
        var members = objectValue ?? [:]
        if keys.count == 1 {
            members[key] = value
        } else {
            members[key] = (members[key] ?? .object([:])).setting(
                Array(keys.dropFirst()), to: value)
        }
        return .object(members)
    }
}
