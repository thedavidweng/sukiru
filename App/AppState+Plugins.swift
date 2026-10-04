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
}

/// Hosts pinned to the sidebar's Plugins section, in the user's order.
/// Stored with `@AppStorage`, so Settings and the sidebar stay in step.
struct SidebarPluginHosts: RawRepresentable, Equatable {
    static let defaultsKey = "sidebarPluginHosts"
    static let all = SidebarPluginHosts(hosts: PluginHost.allCases)

    private(set) var hosts: [PluginHost]

    init(hosts: [PluginHost]) { self.hosts = hosts }

    init?(rawValue: String) {
        var hosts: [PluginHost] = []
        for name in rawValue.split(separator: ",") {
            if let host = PluginHost(rawValue: String(name)), !hosts.contains(host) {
                hosts.append(host)
            }
        }
        self.hosts = hosts
    }

    var rawValue: String { hosts.map(\.rawValue).joined(separator: ",") }

    var hiddenHosts: [PluginHost] { PluginHost.allCases.filter { !hosts.contains($0) } }

    mutating func set(_ host: PluginHost, pinned: Bool) {
        guard pinned != hosts.contains(host) else { return }
        if pinned {
            hosts.append(host)
        } else {
            hosts.removeAll { $0 == host }
        }
    }

    /// Reorders pinned hosts dropped as their raw values; other text is ignored.
    mutating func drop(_ names: [String], at offset: Int) {
        let indices = IndexSet(
            names.compactMap { name in hosts.firstIndex { $0.rawValue == name } })
        if !indices.isEmpty { move(from: indices, to: offset) }
    }

    mutating func move(from source: IndexSet, to destination: Int) {
        hosts.move(fromOffsets: source, toOffset: destination)
    }
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
        pluginManagement.scope = marketplace.scopeRoot == environment.home ? "user" : "project"
        pluginManagement.scopeRoot = marketplace.scopeRoot
        pluginManagement.error = nil
        pluginManagement.showingSheet = true
    }

    func newPluginOperation(host: PluginHost) {
        pluginManagement = PluginManagementState(
            showingSheet: true, host: host, scopeRoot: environment.home)
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
