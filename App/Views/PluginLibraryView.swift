import SukiruCore
import SwiftUI

/// One host's plugins. Each host's plugin system is proprietary, so the list
/// never mixes hosts; it groups that host's installations by scope.
struct PluginLibraryView: View {
    @EnvironmentObject private var state: AppState
    @State private var filter = ""
    @State private var showingMarketplaces = false
    @State private var catalogAction: (() -> Void)?

    private var host: PluginHost { state.pluginHost }

    private var installations: [PluginInstallation] {
        state.pluginInstallations(for: host).filter {
            filter.isEmpty || $0.identifier.localizedCaseInsensitiveContains(filter)
                || $0.sourceTitle.localizedCaseInsensitiveContains(filter)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// User scope first, then each added project, matching the Skills Library.
    private var groups: [(root: String, plugins: [PluginInstallation])] {
        let home = state.environment.home
        let byRoot = Dictionary(grouping: installations, by: \.scopeRoot)
        return byRoot.keys.sorted { lhs, rhs in
            lhs == home || (rhs != home && lhs < rhs)
        }.map { ($0, byRoot[$0] ?? []) }
    }

    private var marketplaces: [PluginMarketplace] {
        (state.report?.pluginInventory?.marketplaces ?? []).filter { $0.host == host }
    }

    var body: some View {
        List(selection: $state.selectedPluginIDs) {
            ForEach(groups, id: \.root) { group in
                Section {
                    ForEach(group.plugins) { plugin in
                        PluginRow(plugin: plugin)
                            .tag(plugin.id)
                    }
                } header: {
                    header(root: group.root, count: group.plugins.count)
                }
            }
            if !issues.isEmpty {
                Section {
                    DisclosureGroup("Inspection Issues") {
                        ForEach(issues, id: \.self) { issue in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: issue.message)
                                Text(verbatim: issue.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .accessibilityIdentifier("sukiru.plugins.inspectionIssues")
                    .help("Inspect plugin inventory errors")
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            PluginContextMenu(plugins: installations.filter { ids.contains($0.id) })
        }
        .onDeleteCommand {
            guard !state.pluginActionsBusy else { return }
            state.removePlugins(state.selectedPlugins)
        }
        .alert(
            "The plugins could not be previewed",
            isPresented: Binding(
                get: { state.pluginManagement.removalError != nil },
                set: { if !$0 { state.pluginManagement.removalError = nil } })
        ) {
        } message: {
            Text(verbatim: state.pluginManagement.removalError ?? "")
        }
        .navigationTitle(Text(verbatim: host.displayName))
        .navigationSubtitle(Text("\(installations.count) plugins"))
        .searchable(text: $filter, placement: .toolbar, prompt: Text("Filter Plugins"))
        .overlay {
            if installations.isEmpty {
                if filter.isEmpty {
                    ContentUnavailableView {
                        Label("No plugins found", systemImage: "puzzlepiece.extension")
                    } description: {
                        Text("This host has no plugins in the user library or added projects.")
                    }
                } else {
                    ContentUnavailableView.search(text: filter)
                }
            }
        }
        .sheet(isPresented: $showingMarketplaces, onDismiss: runCatalogAction) {
            PluginMarketplacesSheet(
                marketplaces: marketplaces,
                onInstall: { entry, marketplace in
                    catalogAction = { state.manageCatalogEntry(entry, marketplace: marketplace) }
                    showingMarketplaces = false
                },
                onManage: { marketplace, action in
                    catalogAction = { state.manageMarketplace(marketplace, action: action) }
                    showingMarketplaces = false
                })
        }
        .onChange(of: installations.map(\.id)) { _, visible in
            state.selectedPluginIDs.formIntersection(visible)
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Install Plugin…") { state.newPluginOperation(host: host) }
                        .accessibilityIdentifier("sukiru.plugins.manage")
                        .help("Preview a plugin installation")
                    if host.hasMarketplaces {
                        Button("Marketplaces…") { showingMarketplaces = true }
                            .accessibilityIdentifier("sukiru.plugins.catalog")
                            .help("Browse configured marketplaces")
                    }
                } label: {
                    Label("Add Plugin", systemImage: "plus")
                }
                .accessibilityIdentifier("sukiru.plugins.add")
                .help("Install a plugin or browse configured marketplaces")
            }
        }
    }

    private var issues: [PluginInventoryIssue] {
        (state.report?.pluginInventory?.issues ?? []).filter { $0.host == host }
    }

    private func header(root: String, count: Int) -> some View {
        HStack(spacing: 6) {
            if root == state.environment.home {
                Text("User Library")
            } else {
                Text(verbatim: URL(fileURLWithPath: root).lastPathComponent)
                    .lineLimit(1)
                    .help(root)
            }
            Spacer(minLength: 8)
            Text(count, format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func runCatalogAction() {
        let action = catalogAction
        catalogAction = nil
        action?()
    }
}

private struct PluginRow: View {
    let plugin: PluginInstallation

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: plugin.displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(verbatim: plugin.sourceTitle)
                    if plugin.scope == "local" {
                        Text("Local project settings")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if plugin.offersEnabledSwitch {
                PluginEnabledToggle(plugin: plugin)
                    .labelsHidden()
                    .controlSize(.mini)
            }
        }
        .accessibilityIdentifier("sukiru.plugins.row.\(plugin.id)")
    }
}

extension AppState {
    func pluginInstallations(for host: PluginHost) -> [PluginInstallation] {
        (report?.pluginInventory?.installations ?? []).filter { $0.host == host }
    }

    var selectedPlugins: [PluginInstallation] {
        pluginInstallations(for: pluginHost).filter { selectedPluginIDs.contains($0.id) }
    }

    /// The plugin the inspector shows; none while several are selected.
    var selectedPlugin: PluginInstallation? {
        selectedPluginIDs.count == 1 ? selectedPlugins.first : nil
    }
}
