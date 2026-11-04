import Foundation

extension PluginLifecyclePlanner {
    public static let hermesActions = ["install", "enable", "disable", "update", "remove", "check"]

    func hermesCapabilities(
        probe: PluginLifecycleProbe, version: String
    ) throws -> PluginLifecycleCapabilities {
        var native: [String] = []
        var limits: [String: String] = [:]
        let empty = PluginInventory(installations: [], marketplaces: [], issues: [])
        for action in Self.hermesActions {
            let request = PluginLifecycleRequest(
                host: .hermes, action: action,
                target: action == "check" ? "*" : "plugin", scope: "user",
                scopeRoot: environment.home)
            if let limit = hermesLimitation(request, version: version, inventory: empty) {
                limits[action] = limit
            } else {
                do {
                    try hermesHelp(probe: probe)
                    native.append(action)
                } catch { limits[action] = error.localizedDescription }
            }
        }
        return PluginLifecycleCapabilities(
            host: .hermes, version: version, nativeCandidates: native, limits: limits)
    }

    /// The subcommands Sukiru runs must all appear in the parent `hermes plugins --help`.
    func hermesHelp(probe: PluginLifecycleProbe) throws {
        try probe.help(
            host: .hermes, arguments: ["plugins"],
            requiredFlags: [
                "install", "remove", "enable", "disable", "update", "check-updates"
            ])
    }

    func hermesArguments(
        _ request: PluginLifecycleRequest, probe: PluginLifecycleProbe
    ) throws -> [String] {
        try hermesHelp(probe: probe)
        let base = ["hermes", "plugins"]
        switch request.action {
        case "install":
            let target = try HermesInstallTarget(request.target)
            return base + ["install", target.argument, "--no-enable"]
        case "enable":
            return base + ["enable", request.target, "--no-allow-tool-override"]
        case "disable", "remove", "update":
            return base + [request.action, request.target]
        case "check":
            return base + ["check-updates", "--json"]
        default:
            throw PluginLifecycleError(
                message: "Hermes exposes no native \(request.action) command")
        }
    }

    func hermesLimitation(
        _ request: PluginLifecycleRequest, version: String, inventory: PluginInventory
    ) -> String? {
        guard PluginHostContract(host: .hermes, version: version) == .hermes else {
            return PluginHostContract.unverified(host: .hermes, version: version, name: "Hermes")
        }
        guard Self.hermesActions.contains(request.action) else {
            return "Hermes exposes no native \(request.action) command. "
                + "Plugins are installed from its catalog or a GitHub repository, "
                + "not from marketplaces Sukiru registers."
        }
        if request.scope != "user" {
            return "Hermes plugins are user-scoped; Sukiru manages them from the user home only."
        }
        if (request.action == "check") != (request.target == "*") {
            return "Hermes checks all plugins at once; name one plugin for \(request.action)."
        }
        return nil
    }

    func hermesImpact(_ request: PluginLifecycleRequest) -> String {
        switch request.action {
        case "install":
            return hermesInstallImpact(request.target)
        case "enable":
            return "Enable \(request.target) in ~/.hermes/config.yaml (plugins.enabled, "
                + "plugins.entries). Its code loads when Hermes next starts. "
                + "Enabling also prepares the plugin's Python dependencies. Hermes does this "
                + "without a prompt when run non-interactively. Sukiru does not roll those packages back. "
                + "Tool override is not granted (--no-allow-tool-override). "
                + "Declared capabilities follow Hermes's own consent."
        case "disable":
            return "Disable \(request.target) in ~/.hermes/config.yaml (plugins.disabled). "
                + "Its files stay in ~/.hermes/plugins."
        case "update":
            return "Update \(request.target) through hermes plugins update. Hermes blocks a "
                + "dangerous security verdict and asks before a caution verdict; Sukiru does not "
                + "pass --force. Sukiru does not roll back the updated plugin files or Python packages."
        case "remove":
            return "Remove ~/.hermes/plugins/\(request.target) through hermes plugins remove. "
                + "Hermes deletes the plugin directory, and Sukiru cannot restore it: anything "
                + "saved inside it is lost. Reinstalling restores the code from the catalog "
                + "commit, not the removed data. Python packages are not removed or restored."
        default:
            return "Check every installed Hermes plugin for updates "
                + "(read-only; hermes plugins check-updates)."
        }
    }

    private func hermesInstallImpact(_ target: String) -> String {
        let source =
            (try? HermesInstallTarget(target)).map { install -> String in
                switch install {
                case .catalog(let name):
                    return "Install \(name) from the Hermes plugin catalog, which pins its "
                        + "repository and commit."
                case .repository(let url):
                    return "Install from the GitHub repository \(url) at its default branch, "
                        + "not a catalog-pinned commit."
                }
            } ?? "Install \(target) through hermes plugins install."
        return source + " The plugin is installed disabled (--no-enable); enabling it is a "
            + "separate step. Hermes clones the repository into ~/.hermes/plugins. A "
            + "non-interactive install skips Python dependencies and leaves them uninstalled. "
            + "Required environment variables are asked for in Hermes, not by Sukiru. "
            + "Rollback restores config.yaml only; undo the install with remove, and Sukiru "
            + "does not roll back the plugin files or Python packages."
    }
}
