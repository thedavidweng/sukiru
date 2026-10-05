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
    var error: String?
    /// Why a removal planned straight from the plugin list could not be previewed.
    var removalError: String?
}

extension AppState {
    func manageCatalogEntry(_ entry: PluginCatalogEntry, marketplace: PluginMarketplace) {
        manageMarketplace(marketplace, action: "install")
        pluginManagement.target = "\(entry.name)@\(marketplace.name)"
    }

    func managePlugin(_ plugin: PluginInstallation, action: String) {
        pluginManagement.host = plugin.host
        pluginManagement.action = action
        pluginManagement.target =
            action == "list"
            ? "*"
            : (action == "disable-local" ? plugin.path ?? "" : plugin.identifier)
        pluginManagement.scope = plugin.scope
        pluginManagement.scopeRoot = plugin.scopeRoot
        pluginManagement.error = nil
        pluginManagement.showingSheet = true
    }

    func manageMarketplace(_ marketplace: PluginMarketplace, action: String) {
        pluginManagement.host = marketplace.host
        pluginManagement.action = action
        pluginManagement.target = marketplace.name
        pluginManagement.scope = marketplace.scope
        pluginManagement.scopeRoot = marketplace.scopeRoot
        pluginManagement.error = nil
        pluginManagement.showingSheet = true
    }

    func newPluginOperation(host: PluginHost) {
        pluginManagement = PluginManagementState(
            showingSheet: true, host: host, scopeRoot: environment.home)
    }

    func previewPluginOperation() {
        let request = PluginLifecycleRequest(
            host: pluginManagement.host,
            action: pluginManagement.action, target: pluginManagement.target,
            scope: pluginManagement.scope, scopeRoot: pluginManagement.scopeRoot)
        pluginManagement.error = nil
        planPluginOperations([request]) { [weak self] error in
            self?.pluginManagement.error = error
        }
    }

    /// Removes plugins the way Finder deletes a selection: one reviewed batch
    /// in Pending Changes, without a per-plugin sheet first.
    func removePlugins(_ plugins: [PluginInstallation]) {
        let requests = plugins.filter { $0.actions.contains("remove") }.map { plugin in
            PluginLifecycleRequest(
                host: plugin.host, action: "remove", target: plugin.identifier,
                scope: plugin.scope, scopeRoot: plugin.scopeRoot)
        }
        guard !requests.isEmpty else { return }
        pluginManagement.removalError = nil
        planPluginOperations(requests) { [weak self] error in
            self?.pluginManagement.removalError = error
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
                    onError(error.localizedDescription)
                }
            }
        }
    }
}
