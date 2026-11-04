import Foundation

struct PluginLifecycleCapture {
    let environment: SukiruEnvironment

    struct Result {
        let paths: [String]
        let requiresHostApproval: Bool
    }

    /// Plugin operations capture host configuration and registry records only. Installed
    /// payloads (plugin code, marketplace checkouts, caches, persistent data) are not captured:
    /// copying them back does not restore what an install, update or removal changed (Python
    /// packages, services, secrets), and their removal is confirmed up front instead.
    func roots(request: PluginLifecycleRequest, inventory: PluginInventory) throws -> Result {
        guard
            !inventory.issues.contains(where: {
                $0.host == request.host && $0.kind.hasPrefix("plugin-config")
            })
        else {
            throw PluginLifecycleError(
                message: "Unreadable host plugin configuration prevents a complete capture plan")
        }
        var paths = baseRoots(host: request.host)
        if request.host == .claude { paths += try claudeRecordRoots() }
        if request.host == .droid { paths += droidRecordRoots() }
        let approval =
            try marketplaceApproval(request: request, inventory: inventory)
            || knownMarketplaceApproval(request: request)
            || addedMarketplaceApproval(request: request)
        for path in paths {
            guard path.hasPrefix("/"), path != "/", path != environment.home else {
                throw PluginLifecycleError(message: "Unbounded capture root: " + path)
            }
        }
        let complete = try PluginCaptureLinks.expand(paths, environment: environment)
        return Result(paths: complete, requiresHostApproval: approval)
    }

    /// Claude's installation and marketplace registries, in the plugin root and the cache root
    /// when it differs. Only the registry files are captured, never the payloads they name.
    private func claudeRecordRoots() throws -> [String] {
        let config =
            environment.externalValue(for: "CLAUDE_CONFIG_DIR")
            ?? HostPathResolver.join(environment.home, ".claude")
        let cache =
            environment.externalValue(for: "CLAUDE_CODE_PLUGIN_CACHE_DIR")
            ?? HostPathResolver.join(config, "plugins")
        var paths: [String] = []
        for root in Set([cache, HostPathResolver.join(config, "plugins")]) {
            paths.append(HostPathResolver.join(root, "installed_plugins.json"))
            paths.append(HostPathResolver.join(root, "known_marketplaces.json"))
            guard let object = try json(at: HostPathResolver.join(root, "installed_plugins.json"))
            else { continue }
            guard let records = object["plugins"] as? [String: [[String: Any]]] else {
                throw PluginLifecycleError(
                    message: "Cannot enumerate installed Claude plugin records")
            }
            for entry in records.values.flatMap({ $0 }) {
                if let project = entry["projectPath"] as? String {
                    paths += Self.claudeSettings(in: HostPathResolver.join(project, ".claude"))
                }
            }
        }
        return paths
    }

    /// Droid keeps one JSON record per installation and per known marketplace; the records are
    /// the registry, while the plugin and marketplace trees beside them are payloads.
    private func droidRecordRoots() -> [String] {
        let root = HostPathResolver.join(environment.home, ".factory/plugins")
        return ["installed_plugins", "known_marketplaces"].map {
            HostPathResolver.join(root, $0)
        }
    }

    /// Approval comes from the catalogs a marketplace declares; their paths are payloads.
    private func marketplaceApproval(
        request: PluginLifecycleRequest, inventory: PluginInventory
    ) throws -> Bool {
        var approval = false
        for marketplace in inventory.marketplaces where marketplace.host == request.host {
            guard let path = marketplace.path else { continue }
            let manifests = [
                ".claude-plugin/marketplace.json", ".agents/plugins/marketplace.json",
                ".cursor-plugin/marketplace.json", ".factory-plugin/marketplace.json"
            ]
            for relative in manifests {
                if let object = try json(at: HostPathResolver.join(path, relative)) {
                    approval =
                        try catalogApproval(object, request: request, marketplace: marketplace)
                        || approval
                }
            }
        }
        return approval
    }

    private func knownMarketplaceApproval(request: PluginLifecycleRequest) throws -> Bool {
        let fetchesCatalog = ["install", "update", "marketplace-refresh"].contains(request.action)
        guard request.host == .claude, fetchesCatalog else { return false }
        let config =
            environment.externalValue(for: "CLAUDE_CONFIG_DIR")
            ?? HostPathResolver.join(environment.home, ".claude")
        let cache =
            environment.externalValue(for: "CLAUDE_CODE_PLUGIN_CACHE_DIR")
            ?? HostPathResolver.join(config, "plugins")
        let known = try json(at: HostPathResolver.join(cache, "known_marketplaces.json"))
        let name =
            request.action == "marketplace-refresh"
            ? request.target
            : request.target.split(separator: "@", maxSplits: 1).last.map(String.init)
        guard let name, let source = known?[name] as? [String: Any] else { return false }
        return containsApproval(source)
    }

    private func catalogApproval(
        _ object: [String: Any], request: PluginLifecycleRequest,
        marketplace: PluginMarketplace
    ) throws -> Bool {
        guard request.host == .claude, ["install", "update"].contains(request.action),
            request.target.hasSuffix("@" + marketplace.name)
        else { return false }
        let name = request.target.split(separator: "@").first.map(String.init)
        let entries = object["plugins"] as? [[String: Any]] ?? []
        var approval = object["headersHelper"] != nil
        for entry in entries where entry["name"] as? String == name {
            approval = approval || containsApproval(entry)
            if request.action == "update", isLocked(entry) {
                throw PluginLifecycleError(
                    message: "Plugin source is version-locked; "
                        + "the host does not offer a lock editor or downgrade operation")
            }
        }
        return approval
    }

    /// A local marketplace added from a path: only its declared approvals matter here.
    private func addedMarketplaceApproval(request: PluginLifecycleRequest) throws -> Bool {
        let localTarget = request.target.hasPrefix("/") || request.target.hasPrefix(".")
        guard request.action == "marketplace-add", localTarget else { return false }
        let path = URL(fileURLWithPath: request.scopeRoot).appendingPathComponent(
            request.target
        ).standardizedFileURL.path
        let absolute = request.target.hasPrefix("/") ? request.target : path
        var approval = false
        for manifest in [
            absolute, HostPathResolver.join(absolute, ".claude-plugin/marketplace.json"),
            HostPathResolver.join(absolute, ".agents/plugins/marketplace.json"),
            HostPathResolver.join(absolute, ".factory-plugin/marketplace.json")
        ] where manifest.hasSuffix(".json") {
            if let object = try json(at: manifest) {
                approval = approval || containsApproval(object)
            }
        }
        return approval
    }

    private func json(at path: String) throws -> [String: Any]? {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory),
            !directory.boolValue
        else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginLifecycleError(message: "Invalid host catalog: " + path)
        }
        return object
    }

    private func containsApproval(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            let command = object["command"] != nil || object["source"] as? String == "command"
            if command || object["headersHelper"] != nil {
                return true
            }
            return object.values.contains(where: containsApproval)
        }
        if let array = value as? [Any] { return array.contains(where: containsApproval) }
        return false
    }

    private func isLocked(_ entry: [String: Any]) -> Bool {
        guard let source = entry["source"] as? [String: Any] else { return false }
        return source["sha"] != nil || source["version"] != nil
    }
}
