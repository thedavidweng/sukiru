import Foundation

extension PluginInventoryReader {
    func readClaude(roots: [String], scope: Scope, issues: inout [Issue]) -> PluginInventory {
        let config =
            environment.externalValue(for: "CLAUDE_CONFIG_DIR")
            ?? HostPathResolver.join(environment.home, ".claude")
        let installed = json(
            HostPathResolver.join(claudePluginRoot(config), "installed_plugins.json"),
            issues: &issues)
        let records = installed?["plugins"] as? [String: [[String: Any]]] ?? [:]
        let userSettings = json(HostPathResolver.join(config, "settings.json"), issues: &issues)
        let installations = claudeInstallations(
            records, roots: roots, scope: scope,
            userSettings: userSettings, issues: &issues)
        let cached = claudeMarketplaces(config, issues: &issues)
        var marketplaces: [PluginMarketplace] = []
        if scope.includes(.user) {
            marketplaces += claudeDeclarations(
                userSettings, root: environment.home, scope: "user", cached: cached,
                issues: &issues)
        }
        if scope.includes(.project) {
            for root in roots {
                for (file, fileScope) in [
                    ("settings.json", "project"), ("settings.local.json", "local")
                ] {
                    let settings = json(
                        HostPathResolver.join(root, ".claude/" + file), issues: &issues)
                    marketplaces += claudeDeclarations(
                        settings, root: root, scope: fileScope, cached: cached, issues: &issues)
                }
            }
        }
        if scope.includes(.user) {
            marketplaces += cached.filter { cache in
                !marketplaces.contains {
                    $0.name == cache.name && $0.sourceIdentity == cache.sourceIdentity
                }
            }
        }
        return PluginInventory(
            installations: installations,
            marketplaces: marketplaces.sorted { $0.id < $1.id }, issues: [])
    }

    private func claudeInstallations(
        _ records: [String: [[String: Any]]], roots: [String], scope: Scope,
        userSettings: [String: Any]?, issues: inout [Issue]
    ) -> [PluginInstallation] {
        var installations: [PluginInstallation] = []
        for (identifier, entries) in records {
            for entry in entries {
                guard let installationScope = entry["scope"] as? String else { continue }
                let root: String
                var settings =
                    installationScope == "managed"
                    ? [:] : (userSettings?["enabledPlugins"] as? [String: Bool] ?? [:])
                if installationScope == "user" || installationScope == "managed" {
                    guard scope.includes(.user) else { continue }
                    root = environment.home
                } else {
                    guard scope.includes(.project), let project = entry["projectPath"] as? String,
                        roots.contains(project)
                    else { continue }
                    root = project
                    for file in ["settings.json", "settings.local.json"] {
                        let object = json(
                            HostPathResolver.join(project, ".claude/" + file), issues: &issues)
                        if let overrides = object?["enabledPlugins"] as? [String: Bool] {
                            settings.merge(overrides) { _, new in new }
                        }
                    }
                }
                // Claude Code treats an installed plugin absent from
                // `enabledPlugins` as disabled; managed settings are not read.
                let enabled = settings[identifier] ?? (installationScope == "managed" ? nil : false)
                let path = entry["installPath"] as? String
                let manifest = path.flatMap {
                    json(HostPathResolver.join($0, ".claude-plugin/plugin.json"), issues: &issues)
                }
                let source =
                    identifier.split(separator: "@", maxSplits: 1).dropFirst().first.map(
                        String.init) ?? ""
                installations.append(
                    PluginInstallation(
                        host: .claude, source: source, identifier: identifier,
                        scope: installationScope, scopeRoot: root,
                        version: entry["version"] as? String, path: path,
                        enablement: enabled.map { $0 ? .enabled : .disabled } ?? .unknown,
                        loadStatus: "unknown",
                        components: components(at: path, manifest: manifest, issues: &issues),
                        details: PluginManifestDetails(manifest, root: path))
                )
            }
        }
        return installations
    }

    private func claudeMarketplaces(
        _ config: String, issues: inout [Issue]
    ) -> [PluginMarketplace] {
        var marketplaces: [PluginMarketplace] = []
        let knownPath = HostPathResolver.join(claudePluginRoot(config), "known_marketplaces.json")
        if let known = json(knownPath, issues: &issues) {
            for (name, value) in known {
                guard let record = value as? [String: Any] else { continue }
                let path = record["installLocation"] as? String
                let source = record["source"] as? [String: Any]
                let address =
                    source?["repo"] as? String ?? source?["url"] as? String
                    ?? source?["path"] as? String ?? name
                let manifest = path.flatMap {
                    json(
                        HostPathResolver.join($0, ".claude-plugin/marketplace.json"),
                        issues: &issues)
                }
                marketplaces.append(
                    PluginMarketplace(
                        host: .claude, name: name, source: address, scopeRoot: environment.home,
                        path: path, plugins: claudeCatalog(manifest, root: path, issues: &issues),
                        evidence: "cached-catalog",
                        ref: source?["ref"] as? String,
                        localSource: Self.claudeLocalSource(source),
                        sourceType: source?["source"] as? String))
            }
        }
        return marketplaces
    }

    private func claudePluginRoot(_ config: String) -> String {
        environment.externalValue(for: "CLAUDE_CODE_PLUGIN_CACHE_DIR")
            ?? HostPathResolver.join(config, "plugins")
    }

    private func claudeCatalog(
        _ manifest: [String: Any]?, root: String?, issues: inout [Issue]
    ) -> [PluginCatalogEntry] {
        guard let manifest, let root else { return [] }
        guard let entries = manifest["plugins"] as? [Any] else {
            issues.append(
                Issue(
                    kind: "plugin-config", path: root + "/.claude-plugin/marketplace.json",
                    message: "Expected a marketplace plugins array"))
            return []
        }
        return entries.compactMap { value -> PluginCatalogEntry? in
            guard let entry = value as? [String: Any], let name = entry["name"] as? String,
                !name.isEmpty
            else {
                issues.append(
                    Issue(
                        kind: "plugin-config", path: root + "/.claude-plugin/marketplace.json",
                        message: "Invalid marketplace plugin entry"))
                return nil
            }
            var listing = PluginCatalogEntry(
                name: name, source: Self.claudeSourceLabel(entry["source"]),
                version: entry["version"] as? String)
            listing.displayName = entry["displayName"] as? String
            listing.summary = entry["description"] as? String
            listing.logo = PluginManifestDetails(entry, root: root).logo
            listing.author =
                (entry["author"] as? [String: Any])?["name"] as? String
                ?? entry["author"] as? String
            listing.homepage = entry["homepage"] as? String
            listing.repository = entry["repository"] as? String
            listing.license = entry["license"] as? String
            listing.categories =
                (entry["category"] as? String).map { [$0] }
                ?? entry["category"] as? [String]
            listing.keywords = entry["keywords"] as? [String]
            listing.suggestedPrompts = entry["suggestedPrompts"] as? [String]
            return listing
        }
    }

    /// A catalog entry's source is a relative path string or a typed object
    /// such as `{"source": "github", "repo": "owner/name"}`.
    static func claudeSourceLabel(_ value: Any?) -> String {
        if let path = value as? String { return path }
        guard let object = value as? [String: Any] else { return "inline" }
        let kind = object["source"] as? String
        let address =
            object["repo"] as? String ?? object["url"] as? String
            ?? object["package"] as? String ?? object["path"] as? String
        switch (kind, address) {
        case (let kind?, let address?): return kind + ":" + address
        case (let kind?, nil): return kind
        case (nil, let address?): return address
        case (nil, nil): return "inline"
        }
    }

    static func claudeLocalSource(_ source: [String: Any]?) -> Bool {
        ["directory", "file"].contains(source?["source"] as? String ?? "")
    }

    private func claudeDeclarations(
        _ settings: [String: Any]?, root: String, scope: String, cached: [PluginMarketplace],
        issues: inout [Issue]
    ) -> [PluginMarketplace] {
        let entries = settings?["extraKnownMarketplaces"] as? [String: [String: Any]] ?? [:]
        return entries.compactMap { name, entry in
            guard let source = entry["source"] as? [String: Any] else { return nil }
            let address =
                source["repo"] as? String ?? source["url"] as? String
                ?? source["path"] as? String ?? name
            let declaredPath = (source["path"] as? String).map {
                resolvePluginPath($0, relativeTo: root)
            }
            let path =
                declaredPath
                ?? cached.first {
                    $0.name == name && $0.source == address && $0.ref == source["ref"] as? String
                        && $0.sourceType == source["source"] as? String
                }?.path
            let manifest = path.flatMap {
                json(HostPathResolver.join($0, ".claude-plugin/marketplace.json"), issues: &issues)
            }
            return PluginMarketplace(
                host: .claude, name: name, source: address, scopeRoot: root,
                path: path, plugins: claudeCatalog(manifest, root: path, issues: &issues),
                scope: scope,
                ref: source["ref"] as? String, localSource: Self.claudeLocalSource(source),
                sourceType: source["source"] as? String,
                catalogState: path == nil ? "unverified" : nil)
        }
    }
}
