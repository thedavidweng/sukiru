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

    private static func tableName(_ line: String) throws -> String? {
        for prefix in ["plugins", "marketplaces"] {
            let pattern = "[\(prefix)."
            if line.hasPrefix(pattern), line.hasSuffix("]") {
                let name = String(line.dropFirst(pattern.count).dropLast())
                guard let decoded = string(name) else { throw CocoaError(.fileReadCorruptFile) }
                return prefix + "." + decoded
            }
        }
        return nil
    }

    private static func field(_ line: String) throws -> (String, String)? {
        if line.isEmpty || line.hasPrefix("#") { return nil }
        guard let equal = line.firstIndex(of: "=") else { throw CocoaError(.fileReadCorruptFile) }
        let key = line[..<equal].trimmingCharacters(in: .whitespaces)
        guard ["enabled", "source", "source_type", "ref"].contains(key) else { return nil }
        let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
        if key == "enabled", value == "true" || value == "false" { return (key, value) }
        guard let decoded = string(value) else { throw CocoaError(.fileReadCorruptFile) }
        return (key, decoded)
    }

    private static func string(_ value: String) -> String? {
        if value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
        }
        guard value.hasPrefix("\"") else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data(value.utf8))
    }
}
