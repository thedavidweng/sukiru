import Foundation

extension PluginLifecyclePlanner {
    func impact(
        _ request: PluginLifecycleRequest, inventory: PluginInventory
    ) throws -> String {
        var affected = inventory.installations.filter {
            $0.host == request.host
                && ($0.identifier == request.target || $0.source == request.target)
        }.map {
            "\($0.identifier) [\($0.scope): \($0.scopeRoot), version \($0.version ?? "unknown")]"
        }.joined(separator: "; ")
        if request.action == "marketplace-remove" && request.host == .claude {
            affected = try claudeCascade(marketplace: request.target)
            return
                "Remove marketplace \(request.target) from \(request.scope). "
                + "Final-scope removal cascades to installations: \(affected.isEmpty ? "none observed" : affected). "
                + "Payloads, saved options, secrets and data may be deleted; "
                + "complete captured file state can be restored."
        }
        if request.action == "marketplace-refresh" {
            return
                "Refresh the entire marketplace \(request.target), including its catalog and fetched versions. "
                + "This is not a single-plugin update; local Codex marketplaces are not upgraded."
        }
        if request.host == .opencode && request.action == "remove" {
            return
                "Remove \(request.target) from global package configuration; "
                + "payloads and auto-discovered local files are not deleted."
        }
        return
            "\(request.action.capitalized) \(request.target) in \(request.scope): \(request.scopeRoot). "
            + "Observed installations: \(affected.isEmpty ? "none" : affected). Host approval remains required; "
            + "saved options, secrets and data are within captured file roots. "
            + "Loading after the operation remains unknown."
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
