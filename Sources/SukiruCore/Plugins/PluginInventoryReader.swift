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

    func components(at path: String?, manifest: [String: Any]?) -> [PluginComponent] {
        guard let path else { return [] }
        var result: [PluginComponent] = []
        for kind in ["skills", "commands", "agents"] {
            let directory = HostPathResolver.join(path, kind)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                continue
            }
            for name in names.sorted() where !name.hasPrefix(".") {
                let componentPath = HostPathResolver.join(directory, name)
                let hasSkill = FileManager.default.fileExists(
                    atPath: HostPathResolver.join(componentPath, "SKILL.md"))
                if kind != "skills" || hasSkill {
                    result.append(PluginComponent(kind: kind, name: name, path: componentPath))
                }
            }
        }
        for key in ["hooks", "mcpServers", "lspServers"] where manifest?[key] != nil {
            result.append(PluginComponent(kind: key, name: key, path: nil))
        }
        return result
    }
}
