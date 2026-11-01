import Foundation

extension PluginLifecyclePlanner {
    func validateInstallMarketplace(
        _ request: PluginLifecycleRequest, inventory: PluginInventory
    ) throws {
        let pieces = request.target.split(separator: "@", maxSplits: 1).map(String.init)
        if request.host == .codex, let selected = request.selectedMarketplaceID {
            let matches = inventory.marketplaces.contains {
                $0.id == selected && $0.host == .codex && $0.scope == "user"
                    && $0.scopeRoot == environment.home && pieces.count == 2
                    && $0.name == pieces[1] && $0.plugins.contains { $0.name == pieces[0] }
            }
            guard matches else {
                throw PluginLifecycleError(
                    message: "Selected Codex marketplace is not available in user scope",
                    reason: .selectedCodexMarketplace)
            }
        }
        let curated = request.host == .codex && request.target.hasSuffix("@openai-curated-remote")
        guard request.host != .opencode, !curated else { return }
        guard pieces.count == 2,
            inventory.marketplaces.contains(where: {
                $0.host == request.host && $0.name == pieces[1]
                    && (request.host != .codex
                        || ($0.scope == "user" && $0.scopeRoot == environment.home))
                    && $0.plugins.contains(where: { $0.name == pieces[0] })
            })
        else {
            throw PluginLifecycleError(
                message: "Choose a plugin from a configured host marketplace",
                reason: .chooseConfiguredMarketplace)
        }
        if request.host == .claude { try validateClaudeSources(pieces[1], inventory: inventory) }
    }

    func validateClaudeSources(_ name: String, inventory: PluginInventory) throws {
        guard inventory.claudeHasUniqueSource(name) else {
            throw PluginLifecycleError(
                message: "Marketplace name refers to multiple sources: " + name,
                reason: .marketplaceSourceConflict(name))
        }
    }
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

    static func isCodexEnablement(_ request: PluginLifecycleRequest) -> Bool {
        request.host == .codex && ["enable", "disable"].contains(request.action)
    }

    func codexLimitation(
        _ request: PluginLifecycleRequest, version: String, inventory: PluginInventory
    ) -> String? {
        guard PluginHostContract(host: .codex, version: version) != nil else {
            return PluginHostContract.unverified(host: .codex, version: version, name: "Codex")
        }
        // Enablement is the documented `enabled` key of the scope's config.toml (ADR-0014).
        if Self.isCodexEnablement(request) { return nil }
        if request.scope != "user" {
            return
                "Codex plugin mutations support user scope only; project configuration is not rewritten."
        }
        if ["update", "check", "replace", "list"].contains(request.action) {
            return
                "Codex exposes no individual \(request.action) operation. "
                + "Marketplace refresh updates the whole configured Git marketplace; "
                + "feature flags are not plugin enablement."
        }
        let localMarketplace = inventory.marketplaces.contains {
            $0.host == .codex && $0.name == request.target && $0.localSource
                && $0.scope == request.scope && $0.scopeRoot == request.scopeRoot
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
        if request.host == .claude {
            try validateClaudeSources(request.target, inventory: inventory)
        }
        let declared = named.contains {
            $0.scope == request.scope && $0.scopeRoot == request.scopeRoot
        }
        let requiresDeclaration =
            request.host == .codex || (request.host == .claude && action == "remove")
        if !declared && requiresDeclaration {
            throw PluginLifecycleError(
                message:
                    "Marketplace \(request.target) is not declared in \(request.scope) scope at "
                    + request.scopeRoot,
                reason: .marketplaceNotDeclared(
                    name: request.target, scope: request.scope, root: request.scopeRoot))
        }
    }
}
