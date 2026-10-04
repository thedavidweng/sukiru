import SukiruCore
import SwiftUI

struct LibraryContainerView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if state.libraryContent == .skills {
                LibraryView()
            } else {
                PluginLibraryView()
            }
        }
        .toolbar {
            ToolbarItem {
                Picker("Library content", selection: $state.libraryContent) {
                    Text("Skills").tag(AppState.LibraryContent.skills)
                    Text("Plugins").tag(AppState.LibraryContent.plugins)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("sukiru.library.content")
                .help("Choose skills or host plugins")
            }
        }
    }
}

struct PluginLibraryView: View {
    @EnvironmentObject private var state: AppState
    @State private var host: PluginHost?
    @State private var filter = ""
    @State private var showingMarketplaces = false
    @State private var catalogAction: (() -> Void)?

    private var installations: [PluginInstallation] {
        (state.report?.pluginInventory?.installations ?? []).filter {
            state.includesPluginScope($0.scopeRoot) && (host == nil || $0.host == host)
                && (filter.isEmpty || $0.identifier.localizedCaseInsensitiveContains(filter)
                    || $0.sourceTitle.localizedCaseInsensitiveContains(filter))
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var marketplaces: [PluginMarketplace] {
        (state.report?.pluginInventory?.marketplaces ?? []).filter {
            state.includesPluginScope($0.scopeRoot) && (host == nil || $0.host == host)
        }
    }

    var body: some View {
        List(selection: $state.selectedPluginID) {
            Section {
                ForEach(installations) { plugin in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: plugin.displayName)
                                .font(.body.weight(.semibold))
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(verbatim: plugin.sourceTitle)
                                if plugin.scopeRoot != state.environment.home {
                                    Text(
                                        verbatim: URL(fileURLWithPath: plugin.scopeRoot)
                                            .lastPathComponent
                                    )
                                    .help(plugin.scopeRoot)
                                }
                                if plugin.scope == "local" {
                                    Text("Local project settings")
                                }
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            AgentLogo(hostID: plugin.host.agentID, size: 14)
                            if plugin.enablement != .unknown {
                                Text(plugin.enablement.localizedTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            Text(
                                verbatim:
                                    "\(plugin.host.displayName), \(plugin.enablement.localizedTitle)"
                            )
                        )
                        .help(plugin.host.displayName)
                    }
                    .tag(plugin.id)
                    .accessibilityIdentifier("sukiru.plugins.row.\(plugin.id)")
                }
            } header: {
                HStack {
                    Text("Plugins")
                    Spacer()
                    Text(installations.count, format: .number)
                }
            }
            if let issues = state.report?.pluginInventory?.issues, !issues.isEmpty {
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
        .navigationTitle("Plugins")
        .navigationSubtitle(Text("\(installations.count) plugins"))
        .searchable(text: $filter, placement: .toolbar, prompt: Text("Filter Plugins"))
        .overlay {
            if installations.isEmpty {
                ContentUnavailableView {
                    Label("No matching plugins", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("Change the host filter or search to see other plugins.")
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
            if let selected = state.selectedPluginID, !visible.contains(selected) {
                state.selectedPluginID = nil
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Install Plugin…") { state.newPluginOperation() }
                        .accessibilityIdentifier("sukiru.plugins.manage")
                        .help("Preview a plugin installation")
                    Button("Marketplaces…") { showingMarketplaces = true }
                        .accessibilityIdentifier("sukiru.plugins.catalog")
                        .help("Browse configured marketplaces")
                } label: {
                    Label("Add Plugin", systemImage: "plus")
                }
                .accessibilityIdentifier("sukiru.plugins.add")
                .help("Install a plugin or browse configured marketplaces")
            }
            ToolbarItem {
                Menu {
                    Picker("Host", selection: $host) {
                        Text("All Hosts").tag(PluginHost?.none)
                        ForEach(PluginHost.allCases, id: \.self) { host in
                            Text(verbatim: host.displayName).tag(PluginHost?.some(host))
                        }
                    }
                } label: {
                    Label("Filter Plugins", systemImage: "line.3.horizontal.decrease.circle")
                }
                .accessibilityIdentifier("sukiru.plugins.host")
                .help("Filter plugin installations by host")
            }
        }
    }

    private func runCatalogAction() {
        let action = catalogAction
        catalogAction = nil
        action?()
    }
}

extension AppState {
    func includesPluginScope(_ root: String) -> Bool {
        switch libraryScope {
        case .all: true
        case .user: root == environment.home
        case .project(let project): root == project
        }
    }

    var selectedPlugin: PluginInstallation? {
        report?.pluginInventory?.installations.first {
            $0.id == selectedPluginID && includesPluginScope($0.scopeRoot)
        }
    }
}
