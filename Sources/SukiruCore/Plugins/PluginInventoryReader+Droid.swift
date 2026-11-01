import Foundation

/// One Droid settings level: `org`, `user` or `project`, with the settings it holds.
private struct DroidLevel {
    let scope: String
    let root: String
    let settings: [String: Any]?
}

/// Droid writes one record per installation under `~/.factory/plugins/installed_plugins` and
/// keeps enablement in the `enabledPlugins` map of the settings level that installed it. A
/// project record names no project, so it belongs to each added project whose settings list it.
extension PluginInventoryReader {
    var droidHome: String { HostPathResolver.join(environment.home, ".factory") }

    /// The documented MDM path; when present it is the authoritative org policy.
    static let droidSystemSettings = "/Library/Application Support/Factory/settings.json"

    func readDroid(roots: [String], scope: Scope, issues: inout [Issue]) -> PluginInventory {
        var levels: [DroidLevel] = []
        if scope.includes(.user) {
            levels.append(
                DroidLevel(
                    scope: "org", root: environment.home,
                    settings: droidOrgSettings(issues: &issues)))
            let user = json(HostPathResolver.join(droidHome, "settings.json"), issues: &issues)
            levels.append(DroidLevel(scope: "user", root: environment.home, settings: user))
        }
        if scope.includes(.project) {
            for root in roots {
                let path = HostPathResolver.join(root, ".factory/settings.json")
                levels.append(
                    DroidLevel(scope: "project", root: root, settings: json(path, issues: &issues)))
            }
        }
        var installations: [PluginInstallation] = []
        let records = HostPathResolver.join(droidHome, "plugins/installed_plugins")
        for file in droidRecordFiles(records, issues: &issues) {
            guard let record = json(file, issues: &issues) else { continue }
            guard let id = record["pluginId"] as? String,
                let entry = record["entry"] as? [String: Any],
                let recordScope = entry["scope"] as? String
            else {
                issues.append(
                    Issue(
                        kind: "plugin-config", path: file,
                        message: "Unrecognized Droid installation record"))
                continue
            }
            guard ["org", "user", "project"].contains(recordScope) else {
                issues.append(
                    Issue(
                        kind: "plugin-record", path: file,
                        message: "Droid installation scope \(recordScope) is not recognized"))
                continue
            }
            for level in levels where level.scope == recordScope {
                if level.scope == "project", Self.droidEnabledPlugins(level.settings)[id] == nil {
                    continue
                }
                installations.append(
                    droidInstallation(id, entry: entry, level: level, issues: &issues))
            }
        }
        return PluginInventory(
            installations: installations,
            marketplaces: droidMarketplaces(
                levels, includeRegistry: scope.includes(.user), issues: &issues),
            issues: [])
    }

    /// Org settings as this Mac holds them: the system-managed file, else the copy Droid
    /// caches from the managed-settings endpoint. A damaged cache is not an inventory error.
    func droidOrgSettings(issues: inout [Issue]) -> [String: Any]? {
        let system = Self.droidSystemSettings
        if !environment.homeIsOverridden, FileManager.default.fileExists(atPath: system) {
            return json(system, issues: &issues)
        }
        var ignored: [Issue] = []
        let cache = json(
            HostPathResolver.join(droidHome, "org-managed-settings.cache.json"), issues: &ignored)
        return cache?["managedSettings"] as? [String: Any]
    }

    static func droidEnabledPlugins(_ settings: [String: Any]?) -> [String: Any] {
        settings?["enabledPlugins"] as? [String: Any] ?? [:]
    }

    private func droidInstallation(
        _ id: String, entry: [String: Any], level: DroidLevel, issues: inout [Issue]
    ) -> PluginInstallation {
        let path = entry["installPath"] as? String
        let manifest = path.flatMap {
            json(HostPathResolver.join($0, ".factory-plugin/plugin.json"), issues: &issues)
        }
        // Droid treats an installation missing from enabledPlugins as disabled; org policy
        // that this Mac does not hold leaves an org installation's state unknown.
        let value = Self.droidEnabledPlugins(level.settings)[id]
        let enablement: PluginEnablement =
            if level.scope == "org" && level.settings == nil {
                .unknown
            } else if let enabled = value as? Bool {
                enabled ? .enabled : .disabled
            } else {
                value == nil ? .disabled : .unknown
            }
        return PluginInstallation(
            host: .droid,
            source: entry["source"] as? String ?? Self.droidPluginID(id)?.marketplace ?? "",
            identifier: id, scope: level.scope, scopeRoot: level.root,
            version: entry["version"] as? String, path: path, enablement: enablement,
            loadStatus: "unknown", components: droidComponents(path),
            name: manifest?["name"] as? String,
            details: PluginManifestDetails(manifest, root: path))
    }

    /// `plugin@marketplace`, split at the first `@` after the first character so a scoped npm
    /// name such as `@scope/plugin@marketplace` keeps its leading `@`.
    public static func droidPluginID(_ id: String) -> (plugin: String, marketplace: String)? {
        guard let first = id.first else { return nil }
        let rest = id.dropFirst()
        guard let separator = rest.firstIndex(of: "@") else { return nil }
        let plugin = String(first) + rest[..<separator]
        let marketplace = String(rest[rest.index(after: separator)...])
        return marketplace.isEmpty ? nil : (plugin, marketplace)
    }

    /// The component folders Droid loads from a cached plugin; Claude Code layouts are
    /// already translated (`agents/` merged into `droids/`) when Droid copies them.
    private func droidComponents(_ path: String?) -> [PluginComponent] {
        guard let path else { return [] }
        var result: [PluginComponent] = []
        droidSkills(HostPathResolver.join(path, "skills"), into: &result)
        for (kind, folder) in [
            ("commands", "commands"), ("droids", "droids"), ("outputStyles", "output-styles")
        ] {
            let directory = HostPathResolver.join(path, folder)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for name in names.sorted() where !name.hasPrefix(".") {
                guard kind == "commands" || name.hasSuffix(".md") else { continue }
                result.append(
                    PluginComponent(
                        kind: kind, name: name, path: HostPathResolver.join(directory, name)))
            }
        }
        var ignored: [Issue] = []
        let hooks = HostPathResolver.join(path, "hooks/hooks.json")
        if let object = json(hooks, issues: &ignored), !object.isEmpty {
            result.append(PluginComponent(kind: "hooks", name: "hooks", path: hooks))
        }
        let mcp = HostPathResolver.join(path, "mcp.json")
        let servers = json(mcp, issues: &ignored)?["mcpServers"] as? [String: Any] ?? [:]
        for name in servers.keys.sorted() {
            result.append(PluginComponent(kind: "mcpServers", name: name, path: mcp))
        }
        return result
    }

    /// Droid searches skill folders recursively; the first directory holding SKILL.md is a skill.
    private func droidSkills(_ directory: String, into result: inout [PluginComponent]) {
        var ignored: [Issue] = []
        for child in antigravityDirectories(directory, issues: &ignored) {
            if FileManager.default.fileExists(atPath: HostPathResolver.join(child, "SKILL.md")) {
                let name = URL(fileURLWithPath: child).lastPathComponent
                result.append(PluginComponent(kind: "skills", name: name, path: child))
            } else {
                droidSkills(child, into: &result)
            }
        }
    }

    private func droidRecordFiles(_ directory: String, issues: inout [Issue]) -> [String] {
        guard FileManager.default.fileExists(atPath: directory) else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory)
                .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
                .map { HostPathResolver.join(directory, $0) }
        } catch {
            issues.append(
                Issue(kind: "plugin-config", path: directory, message: error.localizedDescription))
            return []
        }
    }

    /// The registry under `plugins/known_marketplaces` records where Droid fetched each
    /// marketplace and when, keyed by registered name.
    private func droidRegistry(issues: inout [Issue]) -> [String: [String: Any]] {
        var registered: [String: [String: Any]] = [:]
        let registry = HostPathResolver.join(droidHome, "plugins/known_marketplaces")
        for file in droidRecordFiles(registry, issues: &issues) {
            guard let record = json(file, issues: &issues) else { continue }
            guard let name = record["name"] as? String,
                let entry = record["entry"] as? [String: Any]
            else {
                issues.append(
                    Issue(
                        kind: "plugin-config", path: file,
                        message: "Unrecognized Droid marketplace record"))
                continue
            }
            registered[name] = entry
        }
        return registered
    }

    /// Each settings level declares marketplaces in `extraKnownMarketplaces`; a registered
    /// marketplace no level declares (a CLI-added one) belongs to the user.
    private func droidMarketplaces(
        _ levels: [DroidLevel], includeRegistry: Bool, issues: inout [Issue]
    ) -> [PluginMarketplace] {
        let registered = droidRegistry(issues: &issues)
        var declared: [(level: DroidLevel, name: String)] = []
        for level in levels {
            let entries = level.settings?["extraKnownMarketplaces"] as? [String: Any] ?? [:]
            declared += entries.keys.sorted().map { (level, $0) }
        }
        if includeRegistry {
            let names = Set(declared.map(\.name))
            let user = DroidLevel(scope: "user", root: environment.home, settings: nil)
            declared += registered.keys.sorted().filter { !names.contains($0) }.map { (user, $0) }
        }
        var result: [String: PluginMarketplace] = [:]
        for (level, name) in declared {
            let declaration = (level.settings?["extraKnownMarketplaces"] as? [String: Any])?[name]
            let marketplace = droidMarketplace(
                name, declared: (declaration as? [String: Any])?["source"] as? [String: Any],
                level: level, record: registered[name], issues: &issues)
            if result[marketplace.id] == nil { result[marketplace.id] = marketplace }
        }
        return Array(result.values)
    }

    private func droidMarketplace(
        _ name: String, declared: [String: Any]?, level: DroidLevel, record: [String: Any]?,
        issues: inout [Issue]
    ) -> PluginMarketplace {
        let source = declared ?? record?["source"] as? [String: Any]
        let local = source?["source"] as? String == "local"
        let localPath =
            local
            ? (source?["path"] as? String).map { resolvePluginPath($0, relativeTo: level.root) }
            : nil
        let path = record?["installLocation"] as? String ?? localPath
        return PluginMarketplace(
            host: .droid, name: name, source: Self.droidSourceLabel(source),
            scopeRoot: level.root, path: path,
            plugins: path.map { droidCatalog($0, issues: &issues) } ?? [],
            evidence: level.scope == "org" ? "org-managed" : (record == nil ? "declared" : nil),
            scope: level.scope,
            ref: source?["ref"] as? String ?? source?["sha"] as? String, localSource: local,
            updatedAt: record?["lastUpdated"] as? String)
    }

    static func droidSourceLabel(_ source: [String: Any]?) -> String {
        let repository = source?["repo"] as? String ?? source?["url"] as? String
        let path = source?["path"] as? String
        guard let repository else { return path ?? "unknown" }
        return source?["source"] as? String == "git-subdir"
            ? "\(repository) (\(path ?? ""))" : repository
    }

    /// Droid reads `.factory-plugin/marketplace.json` first, then Claude Code's.
    private func droidCatalog(_ path: String, issues: inout [Issue]) -> [PluginCatalogEntry] {
        let manifest = [".factory-plugin/marketplace.json", ".claude-plugin/marketplace.json"]
            .map { HostPathResolver.join(path, $0) }
            .first { FileManager.default.fileExists(atPath: $0) }
            .flatMap { json($0, issues: &issues) }
        return (manifest?["plugins"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            var listing = PluginCatalogEntry(
                name: name, source: Self.claudeSourceLabel(entry["source"]),
                version: entry["version"] as? String)
            listing.summary = entry["description"] as? String
            listing.categories =
                (entry["category"] as? String).map { [$0] } ?? entry["category"] as? [String]
            listing.homepage = entry["homepage"] as? String
            listing.repository = entry["repository"] as? String
            listing.license = entry["license"] as? String
            listing.keywords = entry["tags"] as? [String] ?? entry["keywords"] as? [String]
            listing.author =
                (entry["author"] as? [String: Any])?["name"] as? String ?? entry["author"]
                as? String
            return listing
        }
    }
}
