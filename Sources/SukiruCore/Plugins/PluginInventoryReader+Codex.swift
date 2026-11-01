import Foundation

extension PluginInventoryReader {
    func readCodex(roots: [String], scope: Scope, issues: inout [Issue]) -> PluginInventory {
        let config =
            environment.externalValue(for: "CODEX_HOME")
            ?? HostPathResolver.join(environment.home, ".codex")
        let user = PluginTOMLReader.tables(
            at: HostPathResolver.join(config, "config.toml"), issues: &issues)
        var installations: [PluginInstallation] = []
        var marketplaces: [PluginMarketplace] = []
        var scopes: [(String, [String: [String: String]])] = []
        if scope.includes(.user) { scopes.append((environment.home, user)) }
        if scope.includes(.project) {
            for root in roots {
                let project = PluginTOMLReader.tables(
                    at: HostPathResolver.join(root, ".codex/config.toml"), issues: &issues)
                // Only explicit project declarations represent project installations.
                scopes.append((root, project))
            }
        }
        for (root, tables) in scopes {
            installations += codexInstallations(tables, config: config, root: root, issues: &issues)
            marketplaces += codexMarketplaces(tables, config: config, root: root, issues: &issues)
        }
        return PluginInventory(installations: installations, marketplaces: marketplaces, issues: [])
    }

    private func codexInstallations(
        _ tables: [String: [String: String]], config: String, root: String, issues: inout [Issue]
    ) -> [PluginInstallation] {
        var installations: [PluginInstallation] = []
        for (key, fields) in tables where key.hasPrefix("plugins.") {
            let identifier = String(key.dropFirst("plugins.".count))
            let pieces = identifier.split(separator: "@", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            let base = HostPathResolver.join(config, "plugins/cache/\(pieces[1])/\(pieces[0])")
            let version = root == environment.home ? CodexPluginVersion.active(in: base) : nil
            let path = version.map { HostPathResolver.join(base, $0) }
            let manifest = path.flatMap { codexManifest(at: $0, issues: &issues) }
            installations.append(
                PluginInstallation(
                    host: .codex, source: pieces[1], identifier: identifier,
                    scope: root == environment.home ? "user" : "project", scopeRoot: root,
                    version: version, path: path,
                    enablement: fields["enabled"] == "false" ? .disabled : .enabled,
                    loadStatus: "unknown",
                    components: components(at: path, manifest: manifest, issues: &issues),
                    installationStatus: path == nil ? "configured" : "installed",
                    details: PluginManifestDetails(manifest, root: path)))
        }
        return installations
    }

    private func codexManifest(at path: String, issues: inout [Issue]) -> [String: Any]? {
        let rootManifest = HostPathResolver.join(path, "plugin.json")
        if let type = entryType(rootManifest) {
            guard type == .typeRegular else { return nil }
            let object = json(rootManifest, issues: &issues)
            let schema = object?["$schema"] as? String
            if schema?.hasPrefix("https://agent-plugins.org/schemas/") == true {
                return object
            }
        }
        for folder in [".codex-plugin", ".claude-plugin", ".cursor-plugin"] {
            let parent = HostPathResolver.join(path, folder)
            guard let type = entryType(parent) else { continue }
            guard type == .typeDirectory else { return nil }
            let manifestPath = HostPathResolver.join(parent, "plugin.json")
            guard let manifestType = entryType(manifestPath) else { continue }
            guard manifestType == .typeRegular else { return nil }
            return json(manifestPath, issues: &issues)
        }
        return nil
    }

    private func entryType(_ path: String) -> FileAttributeType? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.type] as? FileAttributeType
    }

    private func codexMarketplaces(
        _ tables: [String: [String: String]], config: String, root: String, issues: inout [Issue]
    ) -> [PluginMarketplace] {
        var marketplaces: [PluginMarketplace] = []
        for (key, fields) in tables where key.hasPrefix("marketplaces.") {
            let name = String(key.dropFirst("marketplaces.".count))
            guard let source = fields["source"] else { continue }
            let path: String
            if fields["source_type"] == "local" {
                path = resolvePluginPath(source, relativeTo: root)
            } else {
                path = HostPathResolver.join(config, ".tmp/marketplaces/" + name)
            }
            var manifest: [String: Any]?
            var manifestPath = ""
            let candidates = [".agents/plugins/marketplace.json", ".claude-plugin/marketplace.json"]
            let catalogExists = candidates.contains {
                FileManager.default.fileExists(atPath: HostPathResolver.join(path, $0))
            }
            let issueCount = issues.count
            for candidate in candidates {
                if let object = json(HostPathResolver.join(path, candidate), issues: &issues) {
                    manifest = object
                    manifestPath = HostPathResolver.join(path, candidate)
                    break
                }
            }
            let catalog = codexCatalog(manifest, path: manifestPath, issues: &issues)
            marketplaces.append(
                PluginMarketplace(
                    host: .codex, name: name, source: source,
                    scopeRoot: root, path: path, plugins: catalog,
                    scope: root == environment.home ? "user" : "project", ref: fields["ref"],
                    localSource: fields["source_type"] == "local",
                    catalogState: !catalogExists
                        ? "missing"
                        : (issues.count > issueCount ? "unreadable" : "available")))
        }
        return marketplaces
    }

    private func codexCatalog(
        _ manifest: [String: Any]?, path: String, issues: inout [Issue]
    ) -> [PluginCatalogEntry] {
        guard let manifest else { return [] }
        guard let entries = manifest["plugins"] as? [Any] else {
            issues.append(
                Issue(
                    kind: "plugin-config", path: path,
                    message: "Expected a marketplace plugins array"))
            return []
        }
        return entries.compactMap { value in
            guard let entry = value as? [String: Any], let listing = codexCatalogEntry(entry) else {
                issues.append(
                    Issue(
                        kind: "plugin-config", path: path,
                        message: "Invalid marketplace plugin entry"))
                return nil
            }
            return listing
        }
    }

    private func codexCatalogEntry(_ entry: [String: Any]) -> PluginCatalogEntry? {
        guard let pluginName = entry["name"] as? String, !pluginName.isEmpty else { return nil }
        let source = entry["source"] as? [String: Any]
        var listing = PluginCatalogEntry(
            name: pluginName,
            source: source?["path"] as? String ?? Self.claudeSourceLabel(entry["source"]),
            version: entry["version"] as? String)
        let interface = entry["interface"] as? [String: Any]
        listing.displayName = interface?["displayName"] as? String
        listing.summary =
            interface?["shortDescription"] as? String ?? entry["description"] as? String
        listing.author =
            (entry["author"] as? [String: Any])?["name"] as? String
            ?? entry["author"] as? String ?? interface?["developerName"] as? String
        listing.homepage = entry["homepage"] as? String ?? interface?["websiteURL"] as? String
        listing.repository = entry["repository"] as? String
        listing.license = entry["license"] as? String
        listing.categories =
            (entry["category"] as? String).map { [$0] } ?? entry["category"] as? [String]
        listing.keywords = entry["keywords"] as? [String] ?? entry["tags"] as? [String]
        listing.suggestedPrompts = interface?["defaultPrompts"] as? [String]
        listing.logo = (interface?["logo"] as? String).flatMap { logo in
            guard let url = URL(string: logo), url.scheme == "https", url.host != nil else {
                return nil
            }
            return logo
        }
        return listing
    }

    func resolvePluginPath(_ value: String, relativeTo root: String) -> String {
        if value.hasPrefix("~/") {
            return HostPathResolver.join(environment.home, String(value.dropFirst(2)))
        }
        if value.hasPrefix("/") { return value }
        return URL(fileURLWithPath: root).appendingPathComponent(value).standardizedFileURL.path
    }
}
