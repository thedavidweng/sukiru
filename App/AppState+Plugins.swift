import Foundation
import SukiruCore
import SwiftUI

struct PluginManagementState {
    var showingSheet = false
    var planning = false
    var host: PluginHost = .claude
    var action = "install"
    var target = ""
    var scope = "user"
    var scopeRoot = ""
    var gitRef: String?
    var marketplace = ""
    var selectedMarketplaceID: String?
    var strict = false
    /// The install target is a GitHub repository rather than a marketplace listing.
    var repositoryInstall = false
    var error: String?
    /// Why an operation planned without this sheet could not be previewed.
    var directError: String?
}

extension AppState {
    func manageCatalogEntry(_ entry: PluginCatalogEntry, marketplace: PluginMarketplace) {
        manageMarketplace(marketplace, action: "install")
        // Hermes installs a catalog entry by its bare name; the catalog pins its commit.
        pluginManagement.target =
            marketplace.host == .hermes ? entry.name : "\(entry.name)@\(marketplace.name)"
        pluginManagement.selectedMarketplaceID = marketplace.host == .codex ? marketplace.id : nil
        // An org marketplace is installable from user or project scope, not from org scope.
        if marketplace.scope == "org" {
            pluginManagement.scope = "user"
            pluginManagement.scopeRoot = environment.home
        }
    }

    func managePlugin(_ plugin: PluginInstallation, action: String) {
        pluginManagement.host = plugin.host
        pluginManagement.action = action
        pluginManagement.target =
            action == "list"
            ? "*"
            : (["disable-local", "validate"].contains(action)
                ? plugin.path ?? "" : plugin.identifier)
        pluginManagement.scope = plugin.scope
        pluginManagement.scopeRoot = plugin.scopeRoot
        pluginManagement.gitRef = nil
        pluginManagement.marketplace = ""
        pluginManagement.selectedMarketplaceID = nil
        pluginManagement.strict = false
        pluginManagement.repositoryInstall = false
        pluginManagement.error = nil
        pluginManagement.showingSheet = true
    }

    func manageMarketplace(_ marketplace: PluginMarketplace, action: String) {
        pluginManagement.host = marketplace.host
        pluginManagement.action = action
        pluginManagement.target = marketplace.name
        pluginManagement.scope = marketplace.scope
        pluginManagement.scopeRoot = marketplace.scopeRoot
        pluginManagement.gitRef = nil
        pluginManagement.marketplace = ""
        pluginManagement.selectedMarketplaceID = nil
        pluginManagement.strict = false
        pluginManagement.repositoryInstall = false
        pluginManagement.error = nil
        pluginManagement.showingSheet = true
    }

    func newPluginOperation(host: PluginHost, action: String = "install", target: String = "") {
        pluginManagement = PluginManagementState(
            showingSheet: true, host: host, action: action,
            target: ["list", "import"].contains(action) ? "*" : target,
            scopeRoot: environment.home)
    }

    func newPluginRepositoryInstall(host: PluginHost) {
        pluginManagement = PluginManagementState(
            showingSheet: true, host: host, scopeRoot: environment.home, repositoryInstall: true)
    }

    func previewPluginOperation() {
        var target = pluginManagement.target
        if pluginManagement.repositoryInstall {
            do {
                target =
                    "https://github.com/"
                    + (try InstallPlanBuilder.ownerRepo(fromSource: target))
            } catch {
                pluginManagement.error = UserFacingError.message(for: error)
                return
            }
        }
        let request = PluginLifecycleRequest(
            host: pluginManagement.host,
            action: pluginManagement.action, target: target,
            scope: pluginManagement.scope, scopeRoot: pluginManagement.scopeRoot,
            gitRef: pluginManagement.gitRef,
            marketplace: pluginManagement.action == "link" ? pluginManagement.marketplace : nil,
            strict: pluginManagement.action == "validate" ? pluginManagement.strict : nil,
            selectedMarketplaceID: pluginManagement.selectedMarketplaceID)
        pluginManagement.error = nil
        planPluginOperations([request]) { [weak self] error in
            self?.pluginManagement.error = error
        }
    }

    /// Removes plugins the way Finder deletes a selection: one reviewed batch
    /// in Pending Changes, without a per-plugin sheet first.
    func removePlugins(_ plugins: [PluginInstallation]) {
        previewPluginRequests(
            plugins.filter { $0.actions.contains("remove") }.map { plugin in
                PluginLifecycleRequest(
                    host: plugin.host, action: "remove", target: plugin.identifier,
                    scope: plugin.scope, scopeRoot: plugin.scopeRoot)
            })
    }

    /// Factory's official marketplace needs no input, so it skips the sheet.
    func addFactoryMarketplace() {
        previewPluginRequests([
            PluginLifecycleRequest(
                host: .droid, action: "marketplace-add", target: "Factory-AI/factory-plugins",
                scope: "user", scopeRoot: environment.home)
        ])
    }

    private func previewPluginRequests(_ requests: [PluginLifecycleRequest]) {
        guard !requests.isEmpty else { return }
        pluginManagement.directError = nil
        planPluginOperations(requests) { [weak self] error in
            self?.pluginManagement.directError = error
        }
    }

    private func planPluginOperations(
        _ requests: [PluginLifecycleRequest],
        onError: @escaping @MainActor @Sendable (String) -> Void
    ) {
        guard !pluginManagement.planning, !batchMutationInFlight else { return }
        pluginManagement.planning = true
        let environment = Self.makeEnvironment(roots: projectRoots)
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let inventory = PluginInventoryReader(environment: environment).read(ScanRequest())
                let plan = try PluginLifecyclePlanner(environment: environment).plan(
                    requests: requests, inventory: inventory)
                await MainActor.run {
                    guard let self else { return }
                    self.pluginManagement.planning = false
                    self.pluginManagement.showingSheet = false
                    self.surface = .pending
                    self.propose(plan.batch, skipped: plan.instructions)
                }
            } catch {
                await MainActor.run {
                    self?.pluginManagement.planning = false
                    onError(UserFacingError.message(for: error))
                }
            }
        }
    }
}
