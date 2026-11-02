import Foundation

public struct PluginHealthFinding: Codable, Equatable, Sendable, Identifiable {
    public let pluginID: String
    public let kind: String
    public let path: String
    public let scopeRoot: String
    public let historicalEvidence: [String]

    public var id: String { pluginID + ":" + kind }
}

enum PluginHealthAnalyzer {
    static func analyze(
        _ installations: [PluginInstallation], environment: SukiruEnvironment
    ) -> [PluginHealthFinding] {
        let legacy = installations.filter { plugin in
            plugin.host == .opencode
                && plugin.path.map(PluginLocalDisable.hasLegacyDefinition(at:)) == true
        }
        guard !legacy.isEmpty else { return [] }
        let lines = recentLogLines(
            HostPathResolver.join(environment.home, ".local/share/opencode/log/opencode.log"))
        return legacy.compactMap { plugin in
            guard let path = plugin.path else { return nil }
            let evidence = lines.filter {
                $0.contains(path) && ($0.contains("error") || $0.contains("ERROR"))
            }.suffix(3).map(String.init)
            return PluginHealthFinding(
                pluginID: plugin.id, kind: "v1-definition", path: path,
                scopeRoot: plugin.scopeRoot, historicalEvidence: evidence)
        }
    }

    /// OpenCode appends to one log that grows to tens of megabytes; only its latest
    /// errors are evidence, so read the tail.
    static func recentLogLines(_ path: String, limit: Int = 1 << 20) -> [Substring] {
        guard let file = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return [] }
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        guard (try? file.seek(toOffset: start)) != nil, let data = try? file.readToEnd() else {
            return []
        }
        // The cut can land inside a multi-byte character; lossy decoding keeps the rest.
        // swiftlint:disable:next optional_data_string_conversion
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        return start == 0 ? lines : Array(lines.dropFirst())
    }
}
