import Foundation

/// Droid's `droid plugin` and `droid plugin marketplace` commands, plus two documented settings
/// keys no command changes: `enabledPlugins` (Droid has no enable or disable command;
/// ADR-0014 rule 2) and a project's `extraKnownMarketplaces` declaration, which
/// `droid plugin marketplace remove` leaves in place.
extension PluginLifecyclePlanner {
    public static let droidActions = [
        "install", "enable", "disable", "update", "remove", "marketplace-add",
        "marketplace-refresh", "marketplace-remove"
    ]

    static func isDroidSettingsEdit(_ request: PluginLifecycleRequest) -> Bool {
        request.host == .droid
            && (["enable", "disable"].contains(request.action)
                || (request.action == "marketplace-remove" && request.scope == "project"))
    }

    func droidCapabilities(
        probe: PluginLifecycleProbe, version: String
    ) throws -> PluginLifecycleCapabilities {
        var native: [String] = []
        var limits: [String: String] = [:]
        let empty = PluginInventory(installations: [], marketplaces: [], issues: [])
        for action in PluginLifecycleRequest.actions where action != "disable-local" {
            let request = PluginLifecycleRequest(
                host: .droid, action: action, target: "plugin@marketplace", scope: "user",
                scopeRoot: environment.home)
            if let limit = droidLimitation(request, version: version, inventory: empty) {
                limits[action] = limit
            } else if Self.isDroidSettingsEdit(request) {
                native.append(action)
            } else {
                do {
                    try droidHelp(action, probe: probe)
                    native.append(action)
                } catch { limits[action] = error.localizedDescription }
            }
        }
        return PluginLifecycleCapabilities(
            host: .droid, version: version, nativeCandidates: native, limits: limits)
    }

    private static func droidVerb(_ action: String) -> [String] {
        switch action {
        case "remove": ["uninstall"]
        case "marketplace-refresh": ["marketplace", "update"]
        case "marketplace-add": ["marketplace", "add"]
        case "marketplace-remove": ["marketplace", "remove"]
        default: [action]
        }
    }

    private func droidHelp(_ action: String, probe: PluginLifecycleProbe) throws {
        let verb = Self.droidVerb(action)
        try probe.help(
            host: .droid, arguments: ["plugin"] + verb,
            requiredFlags: ["Usage: droid plugin " + verb.joined(separator: " ")]
                + (verb.first == "marketplace" ? [] : ["--scope"]))
    }

    func droidArguments(
        _ request: PluginLifecycleRequest, inventory: PluginInventory, probe: PluginLifecycleProbe
    ) throws -> [String] {
        switch request.action {
        case "install":
            guard let id = PluginInventoryReader.droidPluginID(request.target),
                inventory.marketplaces.contains(where: {
                    $0.host == .droid && $0.name == id.marketplace
                        && ($0.scope != "project" || $0.scopeRoot == request.scopeRoot)
                        && $0.plugins.contains { $0.name == id.plugin }
                })
            else {
                throw PluginLifecycleError(
                    message: "Choose plugin@marketplace from a Droid marketplace this scope sees")
            }
        case "update", "remove":
            guard droidInstallation(request, inventory: inventory) != nil else {
                throw PluginLifecycleError(
                    message: "\(request.target) is not installed in Droid's \(request.scope) scope")
            }
        case "marketplace-refresh", "marketplace-remove":
            try validateMarketplaceTarget(
                request, action: String(request.action.dropFirst("marketplace-".count)),
                inventory: inventory)
        default: break
        }
        try droidHelp(request.action, probe: probe)
        let args = ["droid", "plugin"] + Self.droidVerb(request.action) + [request.target]
        return request.action.hasPrefix("marketplace-") ? args : args + ["--scope", request.scope]
    }

    func droidLimitation(
        _ request: PluginLifecycleRequest, version: String, inventory: PluginInventory
    ) -> String? {
        guard PluginHostContract(host: .droid, version: version) == .droid else {
            return PluginHostContract.unverified(host: .droid, version: version, name: "Droid")
        }
        guard Self.droidActions.contains(request.action) else {
            return "Droid exposes no native \(request.action) command. "
                + "Use /plugins in Droid, then refresh Sukiru."
        }
        if request.scope == "local" {
            return "Droid settings have user and project levels; there is no local scope."
        }
        if request.action == "marketplace-add", request.scope != "user" {
            return "droid plugin marketplace add registers a marketplace in user settings. "
                + "To share one with this project, declare it under extraKnownMarketplaces in "
                + HostPathResolver.join(request.scopeRoot, ".factory/settings.json")
                + ", then refresh Sukiru."
        }
        let declared = inventory.marketplaces.filter {
            $0.host == .droid && $0.name == request.target
        }
        let declaredElsewhere = !declared.isEmpty && !declared.contains { $0.scope == "user" }
        if request.action == "marketplace-remove", request.scope == "user", declaredElsewhere {
            let levels = declared.map { "\($0.scope): \($0.scopeRoot)" }.sorted()
            return "\(request.target) is declared in \(levels.joined(separator: "; ")), "
                + "not in user settings. Organization marketplaces change only in org settings; "
                + "remove a project declaration from that project."
        }
        return nil
    }

    func droidSettingsEdit(
        _ request: PluginLifecycleRequest, inventory: PluginInventory
    ) throws -> BatchCommand {
        guard ["user", "project"].contains(request.scope) else {
            throw PluginLifecycleError(
                message: "Droid settings have user and project levels; there is no local scope")
        }
        let settings = HostPathResolver.join(
            request.scope == "user" ? environment.home : request.scopeRoot,
            ".factory/settings.json")
        if request.action == "marketplace-remove" {
            guard
                inventory.marketplaces.contains(where: {
                    $0.host == .droid && $0.name == request.target && $0.scope == "project"
                        && $0.scopeRoot == request.scopeRoot
                })
            else {
                throw PluginLifecycleError(
                    message: "Marketplace \(request.target) is not declared in \(settings)")
            }
            return try AgentExtensionMutation.editCommand(
                path: settings,
                edits: [.jsonMember(keys: ["extraKnownMarketplaces", request.target], value: nil)],
                intent: "Remove marketplace \(request.target) from extraKnownMarketplaces in "
                    + "\(settings). Droid stops offering it in this project; plugins installed "
                    + "from it stay installed: \(droidInstalled(from: request.target, inventory))")
        }
        guard droidInstallation(request, inventory: inventory) != nil else {
            throw PluginLifecycleError(
                message: "\(request.target) is not installed in Droid's \(request.scope) scope")
        }
        let enable = request.action == "enable"
        // The edit command appends its own sentence after the intent.
        let intent =
            "\(enable ? "Enable" : "Disable") \(request.target) by setting "
            + "enabledPlugins[\"\(request.target)\"] = \(enable) in \(settings). "
            + "Droid reads it when its next session starts." + droidPolicy(request)
        return try AgentExtensionMutation.editCommand(
            path: settings,
            edits: [.jsonMember(keys: ["enabledPlugins", request.target], value: .bool(enable))],
            intent: String(intent.dropLast()))
    }

    func droidImpact(_ request: PluginLifecycleRequest, inventory: PluginInventory) -> String {
        let settings =
            request.scope == "user"
            ? "user settings" : HostPathResolver.join(request.scopeRoot, ".factory/settings.json")
        let place = "\(request.scope): \(request.scopeRoot)"
        let text: String
        switch request.action {
        case "install":
            let id = PluginInventoryReader.droidPluginID(request.target)
            let listing = inventory.marketplaces
                .filter { $0.host == .droid && $0.name == id?.marketplace }
                .flatMap(\.plugins).first { $0.name == id?.plugin }
            text =
                "Install \(id?.plugin ?? request.target) from the Droid marketplace "
                + "\(id?.marketplace ?? "") (listing source \(listing?.source ?? "unknown")) "
                + "in \(place). Droid copies it into ~/.factory/plugins/cache and enables it in "
                + "\(settings). Git and npm sources are fetched; npm sources install with "
                + "--ignore-scripts, so no package scripts run."
        case "update":
            text =
                "Update \(request.target) in \(place). Droid fetches its source again; "
                + "a relative-path plugin follows its marketplace checkout."
        case "remove":
            text =
                "Uninstall \(request.target) from \(place). Droid deletes its installation "
                + "record and its enabledPlugins entry in \(settings)."
        case "marketplace-add":
            text =
                "Register the marketplace \(request.target) in user settings "
                + "(extraKnownMarketplaces). Droid clones a Git source into "
                + "~/.factory/plugins/marketplaces and uses a local directory in place. "
                + "It names the marketplace after the source and appends any #ref or SHA pin."
        case "marketplace-refresh":
            text =
                "Update the marketplace \(request.target): Droid fetches its source again; "
                + "a SHA pin is checked, not moved. Plugins installed from it can change with "
                + "the new checkout."
        default:
            text =
                "Remove the marketplace \(request.target) from user settings and Droid's "
                + "registry. A cloned checkout is deleted; a local directory stays. "
                + "Droid does not uninstall its plugins: "
                + droidInstalled(from: request.target, inventory) + "."
        }
        return text
            + " Captured files can be restored; loading after the operation remains unknown."
            + droidPolicy(request)
    }

    private func droidInstallation(
        _ request: PluginLifecycleRequest, inventory: PluginInventory
    ) -> PluginInstallation? {
        inventory.installations.first {
            $0.host == .droid && $0.identifier == request.target && $0.scope == request.scope
                && $0.scopeRoot == request.scopeRoot
        }
    }

    private func droidInstalled(from marketplace: String, _ inventory: PluginInventory) -> String {
        let installed = inventory.installations.filter {
            $0.host == .droid && $0.source == marketplace
        }.map { "\($0.identifier) [\($0.scope): \($0.scopeRoot)]" }.sorted()
        return installed.isEmpty ? "none observed" : installed.joined(separator: "; ")
    }

    /// Org policy Droid enforces itself; Sukiru reports it rather than second-guessing it.
    private func droidPolicy(_ request: PluginLifecycleRequest) -> String {
        var ignored: [Issue] = []
        let org = PluginInventoryReader(environment: environment).droidOrgSettings(
            issues: &ignored)
        var notes = ""
        let strictMarketplaces = org?["strictKnownMarketplaces"] != nil
        let strictPlugins = org?["strictEnabledPlugins"] as? Bool == true
        if strictMarketplaces, ["install", "marketplace-add"].contains(request.action) {
            notes +=
                " Organization policy (strictKnownMarketplaces) allows only approved "
                + "marketplaces; Droid refuses the rest."
        }
        if strictPlugins, ["install", "enable"].contains(request.action) {
            notes +=
                " Organization policy (strictEnabledPlugins) makes the org list the complete "
                + "set of active plugins; Droid ignores other enables."
        }
        return notes
    }
}
