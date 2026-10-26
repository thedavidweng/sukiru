import Foundation

extension PluginInventoryReader {
    func antigravityConfiguredPlugins(
        _ file: String, relativeTo root: String, visited: inout Set<String>, issues: inout [Issue]
    ) -> [(String, String)] {
        let canonical = URL(fileURLWithPath: file).resolvingSymlinksInPath().path
        guard !visited.contains(canonical) else {
            issues.append(
                Issue(
                    kind: "plugin-config", path: file,
                    message: "Cyclic Antigravity plugins.json inheritance"))
            return []
        }
        guard let config = json(file, issues: &issues, jsonc: true) else { return [] }
        visited.insert(canonical)
        defer { visited.remove(canonical) }
        var result: [(String, String)] = []
        for key in ["inherits", "entries"] {
            guard let value = config[key] else { continue }
            guard let entries = value as? [[String: Any]] else {
                issues.append(
                    Issue(
                        kind: "plugin-config", path: file,
                        message: "Antigravity \(key) must contain path entries"))
                continue
            }
            for entry in entries {
                guard let path = entry["path"] as? String, !path.isEmpty else {
                    issues.append(
                        Issue(
                            kind: "plugin-config", path: file,
                            message: "Antigravity plugin path entry requires a path"))
                    continue
                }
                let localRoot = URL(fileURLWithPath: file).deletingLastPathComponent()
                    .deletingLastPathComponent().path
                let local = antigravityPath(path, relativeTo: localRoot)
                let absolute =
                    FileManager.default.fileExists(atPath: local)
                    ? local : antigravityPath(path, relativeTo: root)
                var candidates =
                    key == "inherits"
                    ? antigravityConfiguredPlugins(
                        absolute, relativeTo: root, visited: &visited, issues: &issues)
                    : antigravityDirectories(absolute, issues: &issues).map { ($0, file) }
                if key == "entries" {
                    candidates += antigravityNestedCandidates(
                        entry, root: absolute, file: file, issues: &issues)
                }
                antigravityPatternEvidence(entry, file: file, issues: &issues)
                result += candidates
            }
        }
        return result
    }

    private func antigravityNestedCandidates(
        _ entry: [String: Any], root: String, file: String, issues: inout [Issue]
    ) -> [(String, String)] {
        let includes = entry["include_only"] as? [String] ?? []
        return includes.filter { $0.contains("/") }.compactMap { name in
            let nested = URL(fileURLWithPath: root).appendingPathComponent(name).standardizedFileURL
                .path
            guard antigravityContained(nested, root: root, issues: &issues),
                DefaultFileSystemProbe().isDirectory(atPath: nested)
            else { return nil }
            return (nested, file)
        }
    }

    private func antigravityPath(_ path: String, relativeTo root: String) -> String {
        let expanded =
            path.hasPrefix("~/")
            ? HostPathResolver.join(environment.home, String(path.dropFirst(2))) : path
        return URL(
            fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: root, isDirectory: true)
        )
        .standardizedFileURL.path
    }

    /// The host has not specified its pattern matcher. Report candidates rather than invent membership.
    private func antigravityPatternEvidence(
        _ entry: [String: Any], file: String, issues: inout [Issue]
    ) {
        for key in ["include_only", "exclude"] {
            guard let value = entry[key] else { continue }
            guard let patterns = value as? [String] else {
                issues.append(
                    Issue(
                        kind: "plugin-config", path: file,
                        message: "Antigravity \(key) requires string patterns"))
                continue
            }
            if !patterns.isEmpty {
                issues.append(
                    Issue(
                        kind: "plugin-discovery", path: file,
                        message: "Antigravity \(key) patterns require host discovery; "
                            + "listed candidates do not establish filtered runtime membership"))
            }
        }
    }

    /// A cached catalog is browseable evidence, not a user registration ledger.
    func antigravityCatalogs(issues: inout [Issue]) -> [PluginMarketplace] {
        let cache = HostPathResolver.join(
            environment.home, ".gemini/antigravity-cli/cache/marketplaces")
        return antigravityDirectories(cache, issues: &issues).compactMap { directory in
            let file = HostPathResolver.join(directory, "marketplace.json")
            guard let catalog = json(file, issues: &issues), let name = catalog["name"] as? String,
                let entries = catalog["plugins"] as? [[String: Any]]
            else { return nil }
            return PluginMarketplace(
                host: .antigravity, name: name, source: directory, scopeRoot: environment.home,
                path: directory,
                plugins: entries.compactMap { entry in
                    guard let name = entry["name"] as? String else { return nil }
                    return PluginCatalogEntry(
                        name: name, source: directory, version: entry["version"] as? String)
                }, evidence: "cached-catalog")
        }
    }
}
