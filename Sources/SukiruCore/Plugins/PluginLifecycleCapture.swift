import Foundation

struct PluginLifecycleCapture {
    let environment: SukiruEnvironment

    struct Result {
        let paths: [String]
        let requiresHostApproval: Bool
    }

    func roots(request: PluginLifecycleRequest, inventory: PluginInventory) throws -> Result {
        guard !inventory.issues.contains(where: { $0.kind.hasPrefix("plugin-config") }) else {
            throw PluginLifecycleError(
                message: "Unreadable host plugin configuration prevents a complete capture plan")
        }
        var paths = baseRoots(host: request.host)
        if request.host == .claude { paths += try claudeRecordRoots() }
        var approval = false
        let catalogs = try marketplaceRoots(request: request, inventory: inventory)
        paths += catalogs.paths
        approval = catalogs.requiresHostApproval
        for installation in inventory.installations where installation.host == request.host {
            if let path = installation.path { paths.append(path) }
            if installation.identifier.hasPrefix("/") { paths.append(installation.identifier) }
            if installation.source.hasPrefix("/") { paths.append(installation.source) }
        }
        let local = try addedMarketplaceRoots(request: request)
        paths += local.paths
        approval = approval || local.requiresHostApproval
        let acquiresPackages = [
            "install", "replace", "list", "check", "update", "marketplace-add",
            "marketplace-refresh"
        ]
        if request.host != .cursor, acquiresPackages.contains(request.action) {
            paths += try npmRoots()
        }
        for path in paths {
            guard path.hasPrefix("/"), path != "/", path != environment.home else {
                throw PluginLifecycleError(message: "Unbounded capture root: " + path)
            }
        }
        let complete = try PluginCaptureLinks.expand(paths, environment: environment)
        return Result(paths: complete, requiresHostApproval: approval)
    }

    private func claudeRecordRoots() throws -> [String] {
        let config =
            environment.externalValue(for: "CLAUDE_CONFIG_DIR")
            ?? HostPathResolver.join(environment.home, ".claude")
        let cache =
            environment.externalValue(for: "CLAUDE_CODE_PLUGIN_CACHE_DIR")
            ?? HostPathResolver.join(config, "plugins")
        var paths: [String] = []
        for root in Set([cache, HostPathResolver.join(config, "plugins")]) {
            guard let object = try json(at: HostPathResolver.join(root, "installed_plugins.json"))
            else { continue }
            collectPaths(object, relativeTo: root, paths: &paths)
            guard let records = object["plugins"] as? [String: [[String: Any]]] else {
                throw PluginLifecycleError(
                    message: "Cannot enumerate installed Claude plugin records")
            }
            for entry in records.values.flatMap({ $0 }) {
                if let project = entry["projectPath"] as? String {
                    paths.append(HostPathResolver.join(project, ".claude"))
                }
            }
        }
        return paths
    }

    private func marketplaceRoots(
        request: PluginLifecycleRequest, inventory: PluginInventory
    ) throws -> Result {
        var paths: [String] = []
        var approval = false
        let marketplaces = inventory.marketplaces.filter { $0.host == request.host }
        for marketplace in marketplaces {
            if let path = marketplace.path { paths.append(path) }
            if marketplace.source.hasPrefix("/") { paths.append(marketplace.source) }
            guard let path = marketplace.path else { continue }
            let manifests = [
                ".claude-plugin/marketplace.json", ".agents/plugins/marketplace.json",
                ".cursor-plugin/marketplace.json"
            ]
            for relative in manifests {
                let manifest = HostPathResolver.join(path, relative)
                if let object = try json(at: manifest) {
                    approval =
                        try catalogApproval(object, request: request, marketplace: marketplace)
                        || approval
                    collectPaths(object, relativeTo: path, paths: &paths)
                }
            }
        }
        let known = try knownMarketplaceRoots(request: request)
        paths += known.paths
        approval = approval || known.requiresHostApproval
        return Result(paths: paths, requiresHostApproval: approval)
    }

    private func knownMarketplaceRoots(request: PluginLifecycleRequest) throws -> Result {
        var paths: [String] = []
        var approval = false
        let fetchesCatalog = ["install", "update", "marketplace-refresh"].contains(request.action)
        if request.host == .claude && fetchesCatalog {
            let config =
                environment.externalValue(for: "CLAUDE_CONFIG_DIR")
                ?? HostPathResolver.join(environment.home, ".claude")
            let known = try json(
                at: HostPathResolver.join(config, "plugins/known_marketplaces.json"))
            let name =
                request.action == "marketplace-refresh"
                ? request.target
                : request.target.split(separator: "@", maxSplits: 1).last.map(String.init)
            if let name, let source = known?[name] as? [String: Any] {
                approval = approval || containsApproval(source)
                collectPaths(source, relativeTo: config, paths: &paths)
            }
        }
        return Result(paths: paths, requiresHostApproval: approval)
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

    private func addedMarketplaceRoots(request: PluginLifecycleRequest) throws -> Result {
        var paths: [String] = []
        var approval = false
        let localTarget = request.target.hasPrefix("/") || request.target.hasPrefix(".")
        if request.action == "marketplace-add", localTarget {
            let path = URL(fileURLWithPath: request.scopeRoot).appendingPathComponent(
                request.target
            ).standardizedFileURL.path
            let absolute = request.target.hasPrefix("/") ? request.target : path
            paths.append(absolute)
            for manifest in [
                absolute, HostPathResolver.join(absolute, ".claude-plugin/marketplace.json"),
                HostPathResolver.join(absolute, ".agents/plugins/marketplace.json")
            ] {
                if manifest.hasSuffix(".json"), let object = try json(at: manifest) {
                    approval = approval || containsApproval(object)
                    collectPaths(object, relativeTo: absolute, paths: &paths)
                }
            }
        }
        return Result(paths: paths, requiresHostApproval: approval)
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

    private func collectPaths(_ value: Any, relativeTo root: String, paths: inout [String]) {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                let pathKeys = ["path", "source", "installPath", "installLocation"]
                if pathKeys.contains(key), let path = child as? String {
                    if path.hasPrefix("/") {
                        paths.append(path)
                    } else if path.hasPrefix("./") || path.hasPrefix("../") {
                        paths.append(
                            URL(fileURLWithPath: root).appendingPathComponent(path)
                                .standardizedFileURL.path)
                    }
                }
                collectPaths(child, relativeTo: root, paths: &paths)
            }
        } else if let array = value as? [Any] {
            for child in array { collectPaths(child, relativeTo: root, paths: &paths) }
        }
    }
}
