import Foundation

/// Hermes keeps user plugins as directories under `~/.hermes/plugins`, enables them by name in
/// `config.yaml`, and caches its curated catalog at `~/.hermes/cache/plugin-catalog.json`.
/// Every file here is Hermes's own; the catalog is a display copy, never installation evidence.
extension PluginInventoryReader {
    static let hermesCatalogName = "hermes-plugin-catalog"
    static let hermesCatalogURL =
        "https://hermes-agent.nousresearch.com/docs/api/plugin-catalog.json"

    func readHermes(scope: Scope, issues: inout [Issue]) -> [PluginInstallation] {
        guard scope.includes(.user) else { return [] }
        let root = HostPathResolver.join(environment.home, ".hermes")
        let configPath = HostPathResolver.join(root, "config.yaml")
        let config = HostConfigFile.yaml(configPath)
        let enabled = Set(config?.strings(at: ["plugins", "enabled"]) ?? [])
        return antigravityDirectories(HostPathResolver.join(root, "plugins"), issues: &issues)
            .compactMap { directory in
                let identifier = URL(fileURLWithPath: directory).lastPathComponent
                let manifestPath = HostPathResolver.join(directory, "plugin.yaml")
                let manifest = HostConfigFile.yaml(manifestPath)?.value
                let name = manifest?["name"]?.stringValue ?? identifier
                let provenance = json(
                    HostPathResolver.join(directory, ".hermes-catalog.json"), issues: &issues)
                let repo = provenance?["repo"] as? String
                let version = manifest?["version"]?.stringValue
                let summary = manifest?["description"]?.stringValue
                return PluginInstallation(
                    host: .hermes, source: repo ?? "local", identifier: identifier,
                    scope: "user", scopeRoot: environment.home, version: version,
                    path: directory,
                    enablement: enabled.contains(identifier) || enabled.contains(name)
                        ? .enabled : .disabled,
                    loadStatus: "unknown", components: [], name: name,
                    details: PluginManifestDetails(summary: summary, logo: nil))
            }
    }

    func hermesCatalogs(issues: inout [Issue]) -> [PluginMarketplace] {
        let path = HostPathResolver.join(environment.home, ".hermes/cache/plugin-catalog.json")
        guard let catalog = json(path, issues: &issues) else { return [] }
        let removed = Set(
            (catalog["removed"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        let entries = catalog["entries"] as? [[String: Any]] ?? []
        let plugins = entries.compactMap { entry -> PluginCatalogEntry? in
            guard let name = entry["name"] as? String, let repo = entry["repo"] as? String,
                !removed.contains(name)
            else { return nil }
            let title = (entry["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let category = (entry["category"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let capabilities = entry["capabilities"] as? [String: Any]
            return PluginCatalogEntry(
                name: name, source: repo, version: entry["version"] as? String,
                displayName: title, summary: entry["description"] as? String,
                logo: (entry["image"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                author: entry["maintainer"] as? String,
                homepage: (entry["docs_url"] as? String) ?? (entry["homepage_url"] as? String),
                repository: repo, license: nil, categories: category.map { [$0] },
                keywords: nil, suggestedPrompts: nil, tier: entry["tier"] as? String,
                knownIssues: entry["known_issues"] as? [String],
                requiredEnvironment: capabilities?["requires_env"] as? [String],
                platforms: entry["platforms"] as? [String])
        }
        guard !plugins.isEmpty else { return [] }
        return [
            PluginMarketplace(
                host: .hermes, name: Self.hermesCatalogName, source: Self.hermesCatalogURL,
                scopeRoot: environment.home, path: nil, plugins: plugins,
                evidence: "cached-catalog", displayName: "Hermes plugin catalog",
                updatedAt: catalog["generated_at"] as? String)
        ]
    }
}
