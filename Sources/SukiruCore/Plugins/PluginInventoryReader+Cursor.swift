import Foundation

extension PluginInventoryReader {
    /// Cache payloads are inspection evidence, never installed/enabled records.
    func readCursor(scope: Scope, issues: inout [Issue]) -> [PluginInstallation] {
        guard scope.includes(.user) else { return [] }
        let root = HostPathResolver.join(environment.home, ".cursor/plugins")
        var result: [PluginInstallation] = []
        let local = HostPathResolver.join(root, "local")
        for name in cursorChildren(local, issues: &issues) {
            let path = HostPathResolver.join(local, name)
            guard cursorContained(path, in: local) else {
                issues.append(
                    Issue(
                        kind: "plugin-containment", path: path,
                        message: "Cursor skips local symlinks outside its local discovery root"))
                continue
            }
            let payload = cursorPayload(path, source: local, status: "discovered", issues: &issues)
            if let plugin = payload {
                result.append(plugin)
            }
        }
        let cache = HostPathResolver.join(root, "cache")
        for source in cursorChildren(cache, issues: &issues) {
            let sourceRoot = HostPathResolver.join(cache, source)
            for name in cursorChildren(sourceRoot, issues: &issues) {
                let pluginRoot = HostPathResolver.join(sourceRoot, name)
                for version in cursorChildren(pluginRoot, issues: &issues) {
                    let path = HostPathResolver.join(pluginRoot, version)
                    guard cursorContained(path, in: cache) else { continue }
                    let payload = cursorPayload(
                        path, source: source, status: "cached", issues: &issues)
                    if let plugin = payload {
                        result.append(plugin)
                    }
                }
            }
        }
        return result
    }

    private func cursorPayload(
        _ path: String, source: String, status: String, issues: inout [Issue]
    ) -> PluginInstallation? {
        let native = HostPathResolver.join(path, ".cursor-plugin/plugin.json")
        let manifestPath =
            FileManager.default.fileExists(atPath: native)
            ? native : HostPathResolver.join(path, "plugin.json")
        guard cursorContained(manifestPath, in: path),
            let manifest = json(manifestPath, issues: &issues)
        else { return nil }
        guard let name = manifest["name"] as? String, !name.isEmpty else {
            issues.append(
                Issue(
                    kind: "plugin-manifest", path: manifestPath,
                    message: "Cursor plugin manifest requires a name"))
            return nil
        }
        let format = manifestPath == native ? "cursor-plugin" : "agent-plugin"
        return PluginInstallation(
            host: .cursor, source: source, identifier: name, scope: "user",
            scopeRoot: environment.home, version: manifest["version"] as? String, path: path,
            enablement: .unknown, loadStatus: "unknown",
            components: cursorComponents(
                path: path, manifest: manifest, native: format == "cursor-plugin", issues: &issues),
            installationStatus: status, format: format)
    }

    func cursorContained(_ path: String, in root: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let boundary = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        return resolved == boundary || resolved.hasPrefix(boundary + "/")
    }

    func cursorChildren(_ path: String, issues: inout [Issue]) -> [String] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(atPath: path).filter {
                !$0.hasPrefix(".")
            }.sorted()
        } catch {
            issues.append(
                Issue(kind: "plugin-config", path: path, message: error.localizedDescription))
            return []
        }
    }
}
