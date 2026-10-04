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

/// The sidebar's Plugins section: every host in the user's order, some
/// hidden. Stored with `@AppStorage` as `claude,-codex,opencode` (a leading
/// `-` hides a host), so Settings and the sidebar stay in step.
struct SidebarPluginHosts: RawRepresentable, Equatable {
    static let defaultsKey = "sidebarPluginHosts"
    static let all = SidebarPluginHosts(rawValue: "")!

    private(set) var order: [PluginHost]
    private(set) var hidden: Set<PluginHost>

    init?(rawValue: String) {
        var order: [PluginHost] = []
        var hidden: Set<PluginHost> = []
        for entry in rawValue.split(separator: ",") {
            let isHidden = entry.hasPrefix("-")
            guard let host = PluginHost(rawValue: String(entry.drop { $0 == "-" })),
                !order.contains(host)
            else { continue }
            order.append(host)
            if isHidden { hidden.insert(host) }
        }
        self.order = order + PluginHost.allCases.filter { !order.contains($0) }
        self.hidden = hidden
    }

    var rawValue: String {
        order.map { (hidden.contains($0) ? "-" : "") + $0.rawValue }.joined(separator: ",")
    }

    /// The hosts the sidebar shows, in order.
    var hosts: [PluginHost] { order.filter { !hidden.contains($0) } }

    mutating func set(_ host: PluginHost, pinned: Bool) {
        if pinned { hidden.remove(host) } else { hidden.insert(host) }
    }

    mutating func move(from source: IndexSet, to destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
    }

    /// Puts `host` where `target` is, shifting the hosts in between.
    mutating func move(_ host: PluginHost, to target: PluginHost) {
        guard let source = order.firstIndex(of: host),
            let destination = order.firstIndex(of: target), source != destination
        else { return }
        order.move(
            fromOffsets: [source], toOffset: destination > source ? destination + 1 : destination)
    }

    /// Swaps a shown host with its shown neighbour; hidden hosts keep their places.
    mutating func move(_ host: PluginHost, by step: Int) {
        let shown = hosts
        guard let index = shown.firstIndex(of: host), shown.indices.contains(index + step),
            let source = order.firstIndex(of: host),
            let target = order.firstIndex(of: shown[index + step])
        else { return }
        order.swapAt(source, target)
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
