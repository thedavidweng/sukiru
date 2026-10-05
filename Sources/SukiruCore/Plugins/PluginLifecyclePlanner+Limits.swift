import Foundation

extension PluginLifecyclePlanner {
    func claudeLimitation(_ request: PluginLifecycleRequest, version: String) -> String? {
        guard PluginHostContract(host: .claude, version: version) != nil else {
            return PluginHostContract.unverified(host: .claude, version: version, name: "Claude")
        }
        if ["replace", "list"].contains(request.action) {
            return "Use Claude's install/update interfaces or passive Library inventory."
        }
        if request.action == "check" {
            return "Claude exposes no verified passive single-plugin update check."
        }
        return nil
    }

    func codexLimitation(
        _ request: PluginLifecycleRequest, version: String, inventory: PluginInventory
    ) -> String? {
        guard PluginHostContract(host: .codex, version: version) != nil else {
            return PluginHostContract.unverified(host: .codex, version: version, name: "Codex")
        }
        if request.scope != "user" {
            return
                "Codex plugin mutations support user scope only; project configuration is not rewritten."
        }
        if ["enable", "disable", "update", "check", "replace", "list"].contains(request.action) {
            return
                "Codex exposes no individual \(request.action) operation. "
                + "Marketplace refresh updates the whole configured Git marketplace; "
                + "feature flags are not plugin enablement."
        }
        let localMarketplace = inventory.marketplaces.contains {
            $0.host == .codex && $0.name == request.target && $0.localSource
        }
        if request.action == "marketplace-refresh" && localMarketplace {
            return
                "\(request.target) is a local Codex marketplace used in place; "
                + "Codex upgrades only Git marketplaces. Edit the local directory instead."
        }
        return nil
    }

    /// Refresh and removal name a marketplace the host already has; a Claude
    /// removal also names the settings scope that declares it.
    func validateMarketplaceTarget(
        _ request: PluginLifecycleRequest, action: String, inventory: PluginInventory
    ) throws {
        let named = inventory.marketplaces.filter {
            $0.host == request.host && $0.name == request.target
        }
        guard !named.isEmpty else {
            throw PluginLifecycleError(message: "Marketplace is not configured: " + request.target)
        }
        let declared = named.contains {
            $0.scope == request.scope && $0.scopeRoot == request.scopeRoot
        }
        if request.host == .claude, action == "remove", !declared {
            throw PluginLifecycleError(
                message:
                    "Marketplace \(request.target) is not declared in \(request.scope) scope at "
                    + request.scopeRoot)
        }
    }
}
