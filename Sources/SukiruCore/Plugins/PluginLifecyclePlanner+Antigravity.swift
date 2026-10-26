import Foundation

extension PluginLifecyclePlanner {
    func antigravityCapabilities(
        probe: PluginLifecycleProbe, version: String
    ) throws -> PluginLifecycleCapabilities {
        var native: [String] = []
        var limits: [String: String] = [:]
        let empty = PluginInventory(installations: [], marketplaces: [], issues: [])
        for action in PluginLifecycleRequest.actions where action != "disable-local" {
            let request = PluginLifecycleRequest(
                host: .antigravity, action: action,
                target: action == "list" ? "*" : "plugin", scope: "user",
                scopeRoot: environment.home)
            if let limit = antigravityLimitation(request, version: version, inventory: empty) {
                limits[action] = limit
            } else {
                do {
                    try antigravityHelp(action, probe: probe)
                    native.append(action)
                } catch { limits[action] = error.localizedDescription }
            }
        }
        return PluginLifecycleCapabilities(
            host: .antigravity, version: version,
            nativeCandidates: native, limits: limits)
    }

    /// Most subcommands treat --help as a target. Verify only the documented parent help.
    private func antigravityHelp(_ action: String, probe: PluginLifecycleProbe) throws {
        let verb = action == "remove" ? "uninstall" : action
        try probe.help(
            host: .antigravity, arguments: ["plugin"],
            requiredFlags: ["Usage: agy plugin", "  " + verb + " "])
        if action == "validate" {
            try probe.help(
                host: .antigravity, arguments: ["plugin", "validate"],
                requiredFlags: ["--json", "--strict"])
        }
    }

    func antigravityArguments(
        _ request: PluginLifecycleRequest, probe: PluginLifecycleProbe
    ) throws -> [String] {
        try antigravityHelp(request.action, probe: probe)
        var args = ["agy", "plugin", request.action == "remove" ? "uninstall" : request.action]
        if request.action == "link" {
            guard let marketplace = request.marketplace, !marketplace.isEmpty,
                !marketplace.hasPrefix("-"),
                marketplace.unicodeScalars.allSatisfy({
                    !CharacterSet.controlCharacters.contains($0)
                })
            else {
                throw PluginLifecycleError(message: "Antigravity link requires a marketplace name")
            }
            args.append(marketplace)
        }
        if request.target != "*" { args.append(request.target) }
        if ["list", "validate"].contains(request.action) { args.append("--json") }
        if request.strict == true { args.append("--strict") }
        return args
    }

    func antigravityLimitation(
        _ request: PluginLifecycleRequest, version: String, inventory: PluginInventory
    ) -> String? {
        guard PluginHostContract(host: .antigravity, version: version) == .antigravity else {
            return PluginHostContract.unverified(
                host: .antigravity, version: version, name: "Antigravity")
        }
        guard
            ["install", "remove", "enable", "disable", "list", "import", "validate", "link"]
                .contains(request.action)
        else {
            return "Antigravity exposes no native \(request.action) command. "
                + "Use Antigravity Customizations for marketplace browsing and updates, then refresh Sukiru. "
                + "Cached catalogs do not establish marketplace registration."
        }
        if request.scope == "local" {
            return
                "Antigravity supports user and project discovery; it has no local settings scope."
        }
        if ["install", "import", "remove"].contains(request.action), request.scope != "user" {
            return "agy plugin \(request.action) manages user plugins only; "
                + "manage project plugins in Antigravity Customizations, then refresh Sukiru."
        }
        if request.action == "list", request.target != "*" {
            return
                "agy plugin list lists all user plugins; use * or Sukiru's passive scoped inventory."
        }
        if request.action == "remove" {
            let matches = inventory.installations.filter {
                $0.host == .antigravity && $0.identifier == request.target
            }
            let nativeRoot = HostPathResolver.join(environment.home, ".gemini/config/plugins")
            let nativePath = HostPathResolver.join(nativeRoot, request.target)
            if !matches.isEmpty, !matches.contains(where: { $0.path == nativePath }) {
                return
                    "agy plugin uninstall cannot delete this built-in, external or CLI-only payload. "
                    + "Disable it through Antigravity instead; its source stays intact."
            }
        }
        return nil
    }

    func antigravityImpact(
        _ request: PluginLifecycleRequest, inventory: PluginInventory
    ) -> String {
        if ["enable", "disable"].contains(request.action) {
            let affected = inventory.installations.filter {
                $0.host == .antigravity && $0.identifier == request.target
            }.map { "\($0.scope): \($0.path ?? $0.scopeRoot)" }.sorted().joined(separator: "; ")
            return "\(request.action.capitalized) Antigravity directory \(request.target). "
                + "The shared config.json preference applies to every plugin with that directory name "
                + "across App, CLI and project discovery: \(affected.isEmpty ? "none observed" : affected). "
                + "Runtime loading remains unknown."
        }
        if ["list", "validate", "link"].contains(request.action) {
            return "Run native Antigravity \(request.action) for \(request.target). "
                + "The result is retained in the command transcript; it does not establish runtime loading."
                + (request.action == "list"
                    ? " Native list reports user plugins; Sukiru's passive inventory includes added projects."
                    : "")
        }
        return "\(request.action.capitalized) \(request.target) through agy plugin in user scope. "
            + "User plugin payloads, preferences, import records and cached catalogs are captured. "
            + "Installation or import may replace existing plugins; restart Antigravity to discover new directories. "
            + "File rollback does not undo running services or external authentication."
    }
}
