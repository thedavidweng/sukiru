import Foundation

/// Reads host-owned files only. This boundary never starts a subprocess.
public struct PluginInventoryReader: Sendable {
    let environment: SukiruEnvironment

    public init(environment: SukiruEnvironment) {
        self.environment = environment
    }

    public func read(_ request: ScanRequest) -> PluginInventory {
        let roots = request.explicitRoots.isEmpty ? environment.projectRoots : request.explicitRoots
        var issues: [Issue] = []
        let claude = readClaude(roots: roots, scope: request.scope, issues: &issues)
        let codex = readCodex(roots: roots, scope: request.scope, issues: &issues)
        let openCode = readOpenCode(roots: roots, scope: request.scope, issues: &issues)
        let installations = (claude.installations + codex.installations + openCode).sorted {
            $0.id < $1.id
        }
        return PluginInventory(
            installations: installations,
            marketplaces: (claude.marketplaces + codex.marketplaces).sorted { $0.id < $1.id },
            issues: issues.sorted { ($0.path, $0.kind) < ($1.path, $1.kind) },
            healthFindings: PluginHealthAnalyzer.analyze(installations, environment: environment))
    }

    func json(_ path: String, issues: inout [Issue]) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let text = String(bytes: data, encoding: .utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let input = path.hasSuffix(".jsonc") ? PluginJSONC.data(text) : data
            guard let object = try JSONSerialization.jsonObject(with: input) as? [String: Any]
            else {
                issues.append(
                    Issue(kind: "plugin-config", path: path, message: "Expected a JSON object"))
                return nil
            }
            return object
        } catch {
            issues.append(
                Issue(kind: "plugin-config", path: path, message: error.localizedDescription))
            return nil
        }
    }

}
