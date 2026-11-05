import SukiruCore
import SwiftUI

/// One host's plugins. Each host's plugin system is proprietary, so the list
/// never mixes hosts; it groups that host's installations by scope.
struct PluginLibraryView: View {
    @EnvironmentObject private var state: AppState
    @State private var filter = ""

    private var host: PluginHost { state.pluginHost }

    private var installations: [PluginInstallation] {
        state.pluginInstallations(for: host).filter { plugin in
            filter.isEmpty || title(plugin).localizedCaseInsensitiveContains(filter)
                || plugin.identifier.localizedCaseInsensitiveContains(filter)
                || (plugin.sourceTitle?.localizedCaseInsensitiveContains(filter) ?? false)
        }.sorted { title($0).localizedStandardCompare(title($1)) == .orderedAscending }
    }

    /// The listing that names a plugin, when the inventory holds a match; a
    /// catalog's name and icon read better than a bare manifest.
    private func listing(_ plugin: PluginInstallation) -> PluginCatalogEntry? {
        state.pluginListing(for: plugin)
    }

    private func title(_ plugin: PluginInstallation) -> String {
        listing(plugin)?.title ?? plugin.displayName
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
        state.pluginMarketplaces(for: host)
    }

    private var showsMarketplace: Bool {
        state.showsPluginMarketplace && host.hasMarketplaceBrowser
    }

    var body: some View {
        Group {
            if showsMarketplace {
                PluginCatalogList(marketplaces: marketplaces, filter: filter)
            } else {
                installedList
            }
        }
        .task(id: showsMarketplace && host == .cursor) {
            if showsMarketplace, host == .cursor, !state.cursorCatalog.loaded {
                state.loadCursorMarketplaces()
            }
        }
        .alert(
            "The plugins could not be previewed",
            isPresented: Binding(
                get: { state.pluginManagement.directError != nil },
                set: { if !$0 { state.pluginManagement.directError = nil } })
        ) {
        } message: {
            Text(verbatim: state.pluginManagement.directError ?? "")
        }
        .navigationTitle(Text(verbatim: host.displayName))
        .navigationSubtitle(
            showsMarketplace
                ? Text(
                    "\(marketplaces.flatMap(\.plugins).filter { $0.matches(filter) }.count) listings"
                )
                : Text("\(installations.count) plugins")
        )
        .searchable(text: filterBinding, placement: .toolbar, prompt: Text("Filter Plugins"))
        .onChange(of: host) { _, _ in
            state.selectedCatalogEntryID = nil
            filter = ""
        }
        // The page picker stays out of the toolbar: there it widens the content
        // column's toolbar section past the column, so the toolbar's divider no
        // longer lines up with the list's.
        .surfaceBar {
            if host.hasMarketplaceBrowser {
                HStack {
                    Picker("Show", selection: $state.showsPluginMarketplace) {
                        Text("Installed").tag(false)
                        Text("Marketplace").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("sukiru.plugins.page")
                    .help("Switch between installed plugins and this host's marketplace")
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .toolbar {
            ColumnAction {
                addMenu
            }
        }
    }

    private var filterBinding: Binding<String> {
        Binding(
            get: { filter },
            set: { value in
                if let selected = state.selectedCatalogEntry, !selected.entry.matches(value) {
                    state.selectedCatalogEntryID = nil
                }
                filter = value
            })
    }

    private var addMenu: some View {
        Menu {
            Button("Install Plugin…") { state.newPluginOperation(host: host) }
                .accessibilityIdentifier("sukiru.plugins.manage")
                .help("Preview a plugin installation")
            if host == .antigravity {
                Button("Install from Repository…") { state.newPluginRepositoryInstall(host: host) }
                    .accessibilityIdentifier("sukiru.plugins.manage.repository")
                    .help("Preview installing a plugin from a GitHub repository")
                ForEach(["import", "validate", "link", "list"], id: \.self) { action in
                    Button(PluginActionTitle.title(action) + "…") {
                        state.newPluginOperation(host: host, action: action)
                    }
                    .accessibilityIdentifier("sukiru.plugins.manage.\(action)")
                    .help("Preview this host’s native plugin command")
                }
            }
            if host.managesMarketplaces {
                Button("Add Marketplace…") {
                    state.newPluginOperation(host: host, action: "marketplace-add")
                }
                .accessibilityIdentifier("sukiru.plugins.marketplace.add")
                .help("Preview registering a marketplace with this host")
            }
        } label: {
            Label("Add Plugin", systemImage: "plus")
        }
        .accessibilityIdentifier("sukiru.plugins.add")
        .help("Install a plugin or browse configured marketplaces")
    }

    private var installedList: some View {
        List(selection: $state.selectedPluginIDs) {
            ForEach(groups, id: \.root) { group in
                Section {
                    ForEach(group.plugins) { plugin in
                        PluginRow(plugin: plugin, listing: listing(plugin))
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
                                Text(verbatim: UserFacingError.message(for: issue))
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
        .onChange(of: installations.map(\.id)) { _, visible in
            state.selectedPluginIDs.formIntersection(visible)
        }
    }

    private var issues: [PluginInventoryIssue] {
        (state.report?.pluginInventory?.issues ?? []).filter { $0.host == host }
    }

    private func header(root: String, count: Int) -> some View {
        ListSectionHeader(title: scopeTitle(root), count: count)
    }

    @ViewBuilder
    private func scopeTitle(_ root: String) -> some View {
        if root == state.environment.home {
            Text("User scope")
        } else {
            Text(verbatim: URL(fileURLWithPath: root).lastPathComponent)
                .help(root)
        }
    }

}

private struct PluginRow: View {
    let plugin: PluginInstallation
    let listing: PluginCatalogEntry?

    /// Laid out like a Marketplace listing, so both tabs read the same.
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PluginLogo(address: listing?.logo ?? plugin.logo, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: listing?.title ?? plugin.displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    enablement
                }
                if let summary = plugin.summary {
                    Text(verbatim: summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(summary)
                }
                if !details.isEmpty {
                    Text(verbatim: details.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityIdentifier("sukiru.plugins.row.\(plugin.id)")
    }

    /// The marketplace, version and project scope a user recognises. A host path
    /// or cache folder is not one of them.
    private var details: [String] {
        var parts = [plugin.sourceTitle, plugin.version].compactMap { $0 }
        if plugin.scope == "local" { parts.append(String(localized: "Local project settings")) }
        return parts
    }

    @ViewBuilder
    private var enablement: some View {
        if plugin.offersEnabledSwitch {
            PluginEnabledToggle(plugin: plugin)
                .labelsHidden()
                .controlSize(.mini)
        } else {
            Text(plugin.enablementStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(plugin.fixedEnablementReason)
        }
    }
}

extension AppState {
    func pluginInstallations(for host: PluginHost) -> [PluginInstallation] {
        (report?.pluginInventory?.installations ?? []).filter { $0.host == host }
    }

    /// The listing whose name and icon describe an installation, when a catalog
    /// names it; see `PluginInventory.catalogEntry(for:)`.
    func pluginListing(for plugin: PluginInstallation) -> PluginCatalogEntry? {
        report?.pluginInventory?.catalogEntry(for: plugin)
    }

    var selectedPlugins: [PluginInstallation] {
        pluginInstallations(for: pluginHost).filter { selectedPluginIDs.contains($0.id) }
    }

    /// The plugin the inspector shows; none while several are selected.
    var selectedPlugin: PluginInstallation? {
        selectedPluginIDs.count == 1 ? selectedPlugins.first : nil
    }
}
