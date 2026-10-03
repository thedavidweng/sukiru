import Foundation
import SukiruCore

struct PluginManagementState {
    var showingSheet = false
    var planning = false
    var host: PluginHost = .claude
    var action = "install"
    var target = ""
    var scope = "user"
    var scopeRoot = ""
    var error: String?
}

extension AppState {
    func manageCatalogEntry(_ entry: PluginCatalogEntry, marketplace: PluginMarketplace) {
        manageMarketplace(marketplace, action: "install")
        pluginManagement.target = "\(entry.name)@\(marketplace.name)"
    }

    func managePlugin(_ plugin: PluginInstallation, action: String) {
        pluginManagement.host = plugin.host
        pluginManagement.action = action
        pluginManagement.target = action == "disable-local" ? plugin.path ?? "" : plugin.identifier
        pluginManagement.scope = plugin.scope
        pluginManagement.scopeRoot = plugin.scopeRoot
        pluginManagement.error = nil
        pluginManagement.showingSheet = true
    }

    func manageMarketplace(_ marketplace: PluginMarketplace, action: String) {
        pluginManagement.host = marketplace.host
        pluginManagement.action = action
        pluginManagement.target = marketplace.name
        pluginManagement.scope = marketplace.scopeRoot == environment.home ? "user" : "project"
        pluginManagement.scopeRoot = marketplace.scopeRoot
        pluginManagement.error = nil
        pluginManagement.showingSheet = true
    }

    func newPluginOperation() {
        pluginManagement = PluginManagementState(showingSheet: true, scopeRoot: environment.home)
    }

    func previewPluginOperation() {
        guard !pluginManagement.planning, !batchMutationInFlight else { return }
        pluginManagement.planning = true
        pluginManagement.error = nil
        let request = PluginLifecycleRequest(
            host: pluginManagement.host,
            action: pluginManagement.action, target: pluginManagement.target,
            scope: pluginManagement.scope, scopeRoot: pluginManagement.scopeRoot)
        let environment = Self.makeEnvironment(roots: projectRoots)
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let inventory = PluginInventoryReader(environment: environment).read(ScanRequest())
                let plan = try PluginLifecyclePlanner(environment: environment).plan(
                    requests: [request], inventory: inventory)
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
                    self?.pluginManagement.error = error.localizedDescription
                }
            }
        }
    }
}
