import Foundation

extension PluginLifecyclePlanner {
    func impact(
        _ request: PluginLifecycleRequest, inventory: PluginInventory
    ) throws -> String {
        let affected = inventory.installations.filter {
            $0.host == request.host
                && ($0.identifier == request.target || $0.source == request.target)
        }.map {
            "\($0.identifier) [\($0.scope): \($0.scopeRoot), version \($0.version ?? "unknown")]"
        }.joined(separator: "; ")
        if request.action == "marketplace-remove", request.host != .cursor {
            return try marketplaceRemovalImpact(request, inventory: inventory, affected: affected)
        }
        if request.host == .claude && request.action == "remove" {
            return claudeRemoveImpact(request, inventory: inventory)
        }
        if request.host == .opencode, let text = openCodeImpact(request, inventory: inventory) {
            return text
        }
        if request.host == .cursor {
            return
                "\(request.action) \(request.target) for the personal Cursor marketplace. "
                + "Removal may uninstall its plugins. "
                + "Catalog/payload changes will be inspected after execution; runtime loading remains unknown."
        }
        if request.action == "marketplace-refresh" {
            return
                "Refresh the entire marketplace \(request.target), including its catalog and fetched versions. "
                + "This is not a single-plugin update; local Codex marketplaces are not upgraded."
        }
        return
            "\(request.action.capitalized) \(request.target) in \(request.scope): \(request.scopeRoot). "
            + "Observed installations: \(affected.isEmpty ? "none" : affected). Host approval remains required; "
            + "saved options, secrets and data are within captured file roots. "
            + "Loading after the operation remains unknown."
    }

    /// Claude cascades only from a marketplace's final declaring scope;
    /// Codex documents no cascade at all.
    private func marketplaceRemovalImpact(
        _ request: PluginLifecycleRequest, inventory: PluginInventory, affected: String
    ) throws -> String {
        let observed = affected.isEmpty ? "none observed" : affected
        if request.host == .codex {
            return
                "Remove marketplace \(request.target) from Codex user configuration and delete its "
                + "installed marketplace snapshot. Codex documents no plugin-uninstall cascade; "
                + "installations from it stay configured: \(observed). "
                + "Complete captured file state can be restored."
        }
        let remaining = inventory.marketplaces.filter {
            $0.host == .claude && $0.name == request.target
                && !($0.scope == request.scope && $0.scopeRoot == request.scopeRoot)
        }
        if !remaining.isEmpty {
            let scopes = remaining.map { "\($0.scope): \($0.scopeRoot)" }.sorted()
            return
                "Remove marketplace \(request.target) from \(request.scope). "
                + "It stays declared in \(scopes.joined(separator: "; ")), "
                + "so this is not its final scope and its installations are not uninstalled. "
                + "Complete captured file state can be restored."
        }
        let cascade = try claudeCascade(marketplace: request.target)
        return
            "Remove marketplace \(request.target) from \(request.scope). "
            + "Final-scope removal cascades to installations: \(cascade.isEmpty ? "none observed" : cascade). "
            + "Payloads, saved options, secrets and data may be deleted; "
            + "complete captured file state can be restored."
    }

    private func openCodeImpact(
        _ request: PluginLifecycleRequest, inventory: PluginInventory
    ) -> String? {
        let packages = inventory.installations.filter {
            $0.host == .opencode && $0.installationStatus != "discovered"
        }
        if request.action == "replace" {
            let name = Self.packageName(request.target)
            let replaced = packages.filter {
                $0.scopeRoot == request.scopeRoot && Self.packageName($0.identifier) == name
            }.map { "\($0.identifier) [\($0.scope)]" }.sorted()
            let observed = replaced.isEmpty ? "none observed" : replaced.joined(separator: "; ")
            return
                "Replace \(name) with \(request.target) in \(request.scope): \(request.scopeRoot). "
                + "Configured versions replaced: \(observed). "
                + "Loading after the operation remains unknown."
        }
        if request.target == "*" {
            let selected = packages.filter {
                request.scope == "user" ? $0.scope == "user" : $0.scopeRoot == request.scopeRoot
            }.map { "\($0.identifier) [\($0.scope)]" }.sorted()
            let observed = selected.isEmpty ? "none" : selected.joined(separator: "; ")
            return
                "\(request.action.capitalized) all package plugins in the selected runtime "
                + "(\(request.scope): \(request.scopeRoot)). "
                + "Configured packages observed: \(observed). "
                + "Loading after the operation remains unknown."
        }
        if request.action == "remove" {
            return
                "Remove \(request.target) from global package configuration; "
                + "payloads and auto-discovered local files are not deleted."
        }
        return nil
    }

    /// `claude plugin uninstall` without `--keep-data` may delete the plugin's
    /// persistent data directory, which holds saved options and secrets.
    private func claudeRemoveImpact(
        _ request: PluginLifecycleRequest, inventory: PluginInventory
    ) -> String {
        let all = inventory.installations.filter {
            $0.host == .claude && $0.identifier == request.target
        }
        let removed = all.first { $0.scope == request.scope && $0.scopeRoot == request.scopeRoot }
        let others = all.filter { $0 != removed }
        let shared = others.filter { removed?.path != nil && $0.path == removed?.path }
        var text =
            "Uninstall \(request.target) from \(request.scope): \(request.scopeRoot). "
            + "Sukiru does not pass --keep-data, so Claude may delete the plugin's persistent data, "
            + "including saved options and secrets; captured files, including that data, can be restored. "
        if others.isEmpty {
            text += "No other scope has this plugin installed. "
        } else {
            text +=
                "Other installations stay: "
                + others.map { "\($0.scope): \($0.scopeRoot)" }.sorted().joined(separator: "; ")
                + ". "
        }
        if !shared.isEmpty {
            text += "They reference the same payload path, whose cleanup Claude decides. "
        }
        return text + "Loading after the operation remains unknown."
    }

    private func claudeCascade(marketplace: String) throws -> String {
        let config =
            environment.externalValue(for: "CLAUDE_CONFIG_DIR")
            ?? HostPathResolver.join(environment.home, ".claude")
        let cache =
            environment.externalValue(for: "CLAUDE_CODE_PLUGIN_CACHE_DIR")
            ?? HostPathResolver.join(config, "plugins")
        var affected = Set<String>()
        for root in Set([cache, HostPathResolver.join(config, "plugins")]) {
            let file = HostPathResolver.join(root, "installed_plugins.json")
            guard FileManager.default.fileExists(atPath: file) else { continue }
            let data = try Data(contentsOf: URL(fileURLWithPath: file))
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let records = object["plugins"] as? [String: [[String: Any]]]
            else {
                throw PluginLifecycleError(message: "Cannot enumerate marketplace removal cascade")
            }
            for (identifier, entries) in records where identifier.hasSuffix("@" + marketplace) {
                for entry in entries {
                    let scope = entry["scope"] as? String ?? "unknown"
                    let project = entry["projectPath"] as? String ?? environment.home
                    let version = entry["version"] as? String ?? "unknown"
                    affected.insert("\(identifier) [\(scope): \(project), version \(version)]")
                }
            }
        }
        return affected.sorted().joined(separator: "; ")
    }
}
