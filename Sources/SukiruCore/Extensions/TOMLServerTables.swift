import Foundation

/// \`[mcp_servers.<name>]\` tables, the layout Codex and Grok document. A server's subtables
/// (\`[mcp_servers.<name>.env]\`) belong to it. Inline-table and other forms are not read, and an
/// unreadable header makes the whole file unreadable rather than partly read.
enum TOMLServerTables {
    struct Table {
        let name: String
        let header: Int
        /// The first line after the server and its subtables.
        var end: Int
        var fields: [String: (line: Int, value: String)] = [:]
    }

    static func tables(_ lines: [String]) throws -> [Table] {
        var result: [Table] = []
        var current: Table?
        var inSubtable = false
        func close(at index: Int) {
            if var open = current {
                open.end = index
                result.append(open)
            }
            current = nil
        }
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let keys = try headerKeys(line)
                if keys.count > 2, keys[0] == "mcp_servers", keys[1] == current?.name {
                    inSubtable = true
                    continue
                }
                close(at: index)
                inSubtable = false
                if keys.count == 2, keys[0] == "mcp_servers" {
                    guard !result.contains(where: { $0.name == keys[1] }) else {
                        throw HookError("Duplicate MCP server table: " + keys[1])
                    }
                    current = Table(name: keys[1], header: index, end: lines.count)
                }
            } else if current != nil, !inSubtable, let (key, value) = field(line) {
                current?.fields[key] = (index, value)
            }
        }
        close(at: lines.count)
        return result
    }

    /// Each server's \`enabled\`, \`command\`, and \`url\` values.
    static func servers(_ text: String) -> [String: JSONValue] {
        guard let tables = try? tables(text.components(separatedBy: "\n")) else { return [:] }
        var result: [String: JSONValue] = [:]
        for table in tables {
            var server: [String: JSONValue] = [:]
            if let enabled = table.fields["enabled"]?.value, ["true", "false"].contains(enabled) {
                server["enabled"] = .bool(enabled == "true")
            }
            for key in ["command", "url"] {
                guard let value = table.fields[key]?.value,
                    let (decoded, rest) = PluginTOMLReader.quoted(value), rest.isEmpty
                else { continue }
                server[key] = .string(decoded)
            }
            result[table.name] = .object(server)
        }
        return result
    }

    /// The text with only \`enabled\` of \`name\` changed or inserted after its header.
    static func setting(_ text: String, name: String, enabled: Bool) throws -> String {
        var lines = text.components(separatedBy: "\n")
        guard let table = try tables(lines).first(where: { $0.name == name }) else {
            throw HookError("No [mcp_servers.\(name)] table")
        }
        if let line = table.fields["enabled"]?.line {
            let indent = lines[line].prefix { $0 == " " || $0 == "\t" }
            lines[line] = indent + "enabled = " + String(enabled)
        } else {
            lines.insert("enabled = " + String(enabled), at: table.header + 1)
        }
        var expected = servers(text)
        var server = expected[name]?.objectValue ?? [:]
        server["enabled"] = .bool(enabled)
        expected[name] = .object(server)
        return try verified(lines, expected: expected)
    }

    /// The text without \`name\`'s table and subtables.
    static func removing(_ text: String, name: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        guard let table = try tables(lines).first(where: { $0.name == name }) else {
            throw HookError("No [mcp_servers.\(name)] table")
        }
        var start = table.header
        var end = table.end
        if end == lines.count {
            // The last table: keep the final newline and drop the blank lines that separated it.
            end = lines.last == "" ? end - 1 : end
            while start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                start -= 1
            }
        }
        lines.removeSubrange(start..<end)
        var expected = servers(text)
        expected[name] = nil
        return try verified(lines, expected: expected)
    }

    private static func verified(
        _ lines: [String], expected: [String: JSONValue]
    ) throws -> String {
        let result = lines.joined(separator: "\n")
        guard servers(result) == expected else {
            throw HookError("The edited TOML would not read back as intended")
        }
        return result
    }

    private static func headerKeys(_ line: String) throws -> [String] {
        guard !line.hasPrefix("[[") else { return [] }
        var rest = line.dropFirst().trimmingCharacters(in: .whitespaces)
        var keys: [String] = []
        while true {
            guard let (key, remainder) = PluginTOMLReader.leadingKey(rest) else {
                throw HookError("Unreadable TOML table header: " + line)
            }
            keys.append(key)
            if remainder.hasPrefix(".") {
                rest = remainder.dropFirst().trimmingCharacters(in: .whitespaces)
                continue
            }
            let trailer = remainder.dropFirst().trimmingCharacters(in: .whitespaces)
            guard remainder.hasPrefix("]"), trailer.isEmpty || trailer.hasPrefix("#") else {
                throw HookError("Unreadable TOML table header: " + line)
            }
            return keys
        }
    }

    private static func field(_ line: String) -> (String, String)? {
        guard !line.isEmpty, !line.hasPrefix("#"), let equal = line.firstIndex(of: "=") else {
            return nil
        }
        let key = line[..<equal].trimmingCharacters(in: .whitespaces)
        let value = HookTOMLDocument.withoutComment(String(line[line.index(after: equal)...]))
            .trimmingCharacters(in: .whitespaces)
        return (key, value)
    }
}
