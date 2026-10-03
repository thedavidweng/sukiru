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
        let logPath = HostPathResolver.join(
            environment.home, ".local/share/opencode/log/opencode.log")
        let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        return installations.compactMap { plugin in
            guard plugin.host == .opencode, let path = plugin.path,
                PluginLocalDisable.hasLegacyDefinition(at: path)
            else { return nil }
            let evidence = log.split(separator: "\n").filter {
                $0.contains(path) && ($0.contains("error") || $0.contains("ERROR"))
            }.suffix(3).map(String.init)
            return PluginHealthFinding(
                pluginID: plugin.id, kind: "v1-definition", path: path,
                scopeRoot: plugin.scopeRoot, historicalEvidence: evidence)
        }
    }
}
