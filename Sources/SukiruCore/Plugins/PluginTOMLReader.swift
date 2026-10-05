import Foundation

/// The plugin tables use the host's documented string/bool TOML fields.
/// Unsupported syntax is reported rather than interpreted as empty state.
enum PluginTOMLReader {
    static func tables(at path: String, issues: inout [Issue]) -> [String: [String: String]] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            var table: String?
            var result: [String: [String: String]] = [:]
            for rawLine in text.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") {
                    table = try tableName(line)
                    if let table { result[table, default: [:]] = result[table] ?? [:] }
                } else if let table, let field = try field(line) {
                    result[table, default: [:]][field.0] = field.1
                }
            }
            return result
        } catch {
            issues.append(
                Issue(
                    kind: "plugin-config", path: path,
                    message: "Cannot interpret plugin TOML tables: \(error.localizedDescription)"))
            return [:]
        }
    }

    /// The `plugins.<id>` or `marketplaces.<name>` table a header opens, or
    /// nil for any other table, including nested subtables such as
    /// `[plugins."x".options]`, whose fields are not plugin facts.
    private static func tableName(_ line: String) throws -> String? {
        guard !line.hasPrefix("[[") else { return nil }
        let header = line.dropFirst().trimmingCharacters(in: .whitespaces)
        for prefix in ["plugins", "marketplaces"] where header.hasPrefix(prefix + ".") {
            let rest = header.dropFirst(prefix.count + 1).trimmingCharacters(in: .whitespaces)
            guard let (key, remainder) = leadingKey(rest) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if remainder.hasPrefix(".") { return nil }
            let trailer = remainder.dropFirst().trimmingCharacters(in: .whitespaces)
            guard remainder.hasPrefix("]"), trailer.isEmpty || trailer.hasPrefix("#") else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return prefix + "." + key
        }
        return nil
    }

    private static func field(_ line: String) throws -> (String, String)? {
        if line.isEmpty || line.hasPrefix("#") { return nil }
        guard let equal = line.firstIndex(of: "=") else { throw CocoaError(.fileReadCorruptFile) }
        let key = line[..<equal].trimmingCharacters(in: .whitespaces)
        guard ["enabled", "source", "source_type", "ref"].contains(key) else { return nil }
        let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
        if key == "enabled" {
            let bare = value.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
            if bare == "true" || bare == "false" { return (key, bare) }
        }
        guard let (decoded, remainder) = quoted(value),
            remainder.isEmpty || remainder.hasPrefix("#")
        else { throw CocoaError(.fileReadCorruptFile) }
        return (key, decoded)
    }

    /// The first dotted-key segment, bare or quoted, and what follows it.
    private static func leadingKey(_ text: String) -> (String, String)? {
        if let (key, remainder) = quoted(text) { return (key, remainder) }
        let bare = text.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        guard !bare.isEmpty else { return nil }
        return (String(bare), text.dropFirst(bare.count).trimmingCharacters(in: .whitespaces))
    }

    /// A leading basic or literal TOML string, and the trimmed text after it.
    private static func quoted(_ text: String) -> (String, String)? {
        guard let quote = text.first, quote == "\"" || quote == "'" else { return nil }
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            if quote == "\"" && character == "\\" {
                index = text.index(after: index)
                guard index < text.endIndex else { return nil }
            } else if character == quote {
                let literal = String(text[...index])
                let value: String? =
                    quote == "'"
                    ? String(literal.dropFirst().dropLast())
                    : try? JSONDecoder().decode(String.self, from: Data(literal.utf8))
                let remainder = text[text.index(after: index)...]
                    .trimmingCharacters(in: .whitespaces)
                return value.map { ($0, remainder) }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
