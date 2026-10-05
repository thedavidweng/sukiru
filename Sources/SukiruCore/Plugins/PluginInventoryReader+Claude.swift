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
        // Registered catalogs come first so their install location wins over a
        // bare user-settings declaration of the same name.
        var marketplaces: [PluginMarketplace] = []
        if scope.includes(.user) {
            marketplaces += claudeMarketplaces(config, issues: &issues)
            marketplaces += claudeDeclarations(
                userSettings, root: environment.home, scope: "user", config: config,
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
                        settings, root: root, scope: fileScope, config: config, issues: &issues)
                }
            }
        }
        var uniqueMarketplaces: [String: PluginMarketplace] = [:]
        for marketplace in marketplaces where uniqueMarketplaces[marketplace.id] == nil {
            uniqueMarketplaces[marketplace.id] = marketplace
        }
        return PluginInventory(
            installations: installations,
            marketplaces: uniqueMarketplaces.values.sorted { $0.id < $1.id }, issues: [])
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
                let enabled = settings[identifier]
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
                        components: components(at: path, manifest: manifest, issues: &issues))
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
                        path: path, plugins: claudeCatalog(manifest),
                        ref: source?["ref"] as? String,
                        localSource: Self.claudeLocalSource(source)))
            }
        }
        return marketplaces
    }

    private func claudePluginRoot(_ config: String) -> String {
        environment.externalValue(for: "CLAUDE_CODE_PLUGIN_CACHE_DIR")
            ?? HostPathResolver.join(config, "plugins")
    }

    private func claudeCatalog(_ manifest: [String: Any]?) -> [PluginCatalogEntry] {
        let entries = manifest?["plugins"] as? [[String: Any]] ?? []
        return entries.compactMap { entry -> PluginCatalogEntry? in
            guard let name = entry["name"] as? String else { return nil }
            return PluginCatalogEntry(
                name: name, source: Self.claudeSourceLabel(entry["source"]),
                version: entry["version"] as? String)
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
        _ settings: [String: Any]?, root: String, scope: String, config: String,
        issues: inout [Issue]
    ) -> [PluginMarketplace] {
        let entries = settings?["extraKnownMarketplaces"] as? [String: [String: Any]] ?? [:]
        return entries.compactMap { name, entry in
            guard let source = entry["source"] as? [String: Any] else { return nil }
            let address =
                source["repo"] as? String ?? source["url"] as? String
                ?? source["path"] as? String ?? name
            let path =
                (source["path"] as? String).map { resolvePluginPath($0, relativeTo: root) }
                ?? HostPathResolver.join(claudePluginRoot(config), "marketplaces/" + name)
            let manifest = json(
                HostPathResolver.join(path, ".claude-plugin/marketplace.json"), issues: &issues)
            return PluginMarketplace(
                host: .claude, name: name, source: address, scopeRoot: root,
                path: path, plugins: claudeCatalog(manifest), scope: scope,
                ref: source["ref"] as? String, localSource: Self.claudeLocalSource(source))
        }
    }
}
