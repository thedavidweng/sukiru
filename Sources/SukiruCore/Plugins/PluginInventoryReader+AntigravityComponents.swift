import Foundation

extension PluginInventoryReader {
    func antigravityComponents(
        _ root: String, manifest: [String: Any], manifestPath: String, issues: inout [Issue]
    ) -> [PluginComponent] {
        var result: [PluginComponent] = []
        for kind in ["skills", "agents", "rules"] {
            appendAntigravityFiles(
                HostPathResolver.join(root, kind), kind: kind,
                root: root, result: &result, issues: &issues)
        }
        if let skills = manifest["skills"] {
            let paths = (skills as? [String]) ?? (skills as? String).map { [$0] } ?? []
            for path in paths {
                let resolved = URL(
                    fileURLWithPath: path, relativeTo: URL(fileURLWithPath: root, isDirectory: true)
                )
                .standardizedFileURL.path
                appendAntigravityFiles(
                    resolved, kind: "skills",
                    root: root, result: &result, issues: &issues)
            }
        }
        for (file, kind) in [("mcp_config.json", "mcpServers"), ("hooks.json", "hooks")] {
            let path = HostPathResolver.join(root, file)
            guard antigravityContained(path, root: root, issues: &issues),
                let config = json(path, issues: &issues, jsonc: true)
            else { continue }
            let entries = kind == "hooks" ? config : config["mcpServers"] as? [String: Any] ?? [:]
            result += entries.keys.sorted().map {
                PluginComponent(kind: kind, name: $0, path: path)
            }
        }
        let sidecars = HostPathResolver.join(root, "sidecars")
        if antigravityContained(sidecars, root: root, issues: &issues) {
            for path in antigravityDirectories(sidecars, issues: &issues) {
                let file = HostPathResolver.join(path, "sidecar.json")
                guard antigravityContained(file, root: root, issues: &issues),
                    json(file, issues: &issues, jsonc: true) != nil
                else { continue }
                result.append(
                    PluginComponent(
                        kind: "sidecars",
                        name: URL(fileURLWithPath: path).lastPathComponent, path: file))
            }
        }
        appendAntigravityDeclarations(
            root, manifest: manifest, manifestPath: manifestPath,
            result: &result, issues: &issues)
        var seen = Set<String>()
        return result.filter { seen.insert("\($0.kind)|\($0.name)|\($0.path ?? "")").inserted }
    }

    private func appendAntigravityFiles(
        _ path: String, kind: String, root: String, result: inout [PluginComponent],
        issues: inout [Issue]
    ) {
        guard FileManager.default.fileExists(atPath: path),
            antigravityContained(path, root: root, issues: &issues)
        else { return }
        let marker = HostPathResolver.join(path, "SKILL.md")
        if kind == "skills", FileManager.default.fileExists(atPath: marker) {
            if antigravityContained(marker, root: root, issues: &issues) {
                result.append(
                    PluginComponent(
                        kind: kind,
                        name: URL(fileURLWithPath: path).lastPathComponent, path: path))
            }
            return
        }
        do {
            for name in try FileManager.default.contentsOfDirectory(atPath: path).sorted()
            where !name.hasPrefix(".") {
                let file = HostPathResolver.join(path, name)
                let required = kind == "skills" ? HostPathResolver.join(file, "SKILL.md") : file
                guard antigravityContained(required, root: root, issues: &issues),
                    FileManager.default.fileExists(atPath: required),
                    kind == "skills" || name.hasSuffix(".md")
                else { continue }
                result.append(PluginComponent(kind: kind, name: name, path: file))
            }
        } catch {
            issues.append(
                Issue(kind: "plugin-config", path: path, message: error.localizedDescription))
        }
    }

    private func appendAntigravityDeclarations(
        _ root: String, manifest: [String: Any], manifestPath: String,
        result: inout [PluginComponent], issues: inout [Issue]
    ) {
        // These are authored declarations. Their presence does not prove runtime membership.
        for kind in ["skills", "rules", "agents", "sidecars"] {
            let file = kind + ".json"
            let path = HostPathResolver.join(root, file)
            guard antigravityContained(path, root: root, issues: &issues),
                json(path, issues: &issues, jsonc: true) != nil
            else { continue }
            result.append(PluginComponent(kind: kind, name: file, path: path))
        }
        let extensions = manifest["extensions"] as? [String: Any]
        let google = extensions?["com.google.antigravity"] as? [String: Any]
        let providers = google?["contextProviders"] as? [String: Any] ?? [:]
        result += providers.keys.sorted().map {
            PluginComponent(kind: "contextProviders", name: $0, path: manifestPath)
        }
    }
}
