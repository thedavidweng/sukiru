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

    private var installations: [PluginInstallation] {
        (state.report?.pluginInventory?.installations ?? []).filter {
            state.includesPluginScope($0.scopeRoot) && (host == nil || $0.host == host)
                && (filter.isEmpty || $0.identifier.localizedCaseInsensitiveContains(filter))
        }
    }

    private var marketplaces: [PluginMarketplace] {
        (state.report?.pluginInventory?.marketplaces ?? []).filter {
            state.includesPluginScope($0.scopeRoot) && (host == nil || $0.host == host)
        }
    }

    var body: some View {
        List(selection: $state.selectedPluginID) {
            Section("Plugin Installations") {
                ForEach(installations) { plugin in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: plugin.identifier)
                        Text(
                            verbatim:
                                "\(plugin.host.rawValue) · \(plugin.scope) · \(plugin.scopeRoot)"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .tag(plugin.id)
                    .accessibilityIdentifier("sukiru.plugins.row.\(plugin.id)")
                }
            }
            Section("Configured Marketplaces") {
                ForEach(marketplaces) { marketplace in
                    marketplaceRow(marketplace)
                }
            }
            if let issues = state.report?.pluginInventory?.issues, !issues.isEmpty {
                Section("Inspection Issues") {
                    ForEach(issues, id: \.self) { issue in
                        Text(verbatim: "\(issue.path): \(issue.message)")
                    }
                }
            }
        }
        .navigationTitle("Plugins")
        .searchable(text: $filter, prompt: Text("Filter Plugins"))
        .onChange(of: installations.map(\.id)) { _, visible in
            if let selected = state.selectedPluginID, !visible.contains(selected) {
                state.selectedPluginID = nil
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Manage Plugins…") { state.newPluginOperation() }
                    .accessibilityIdentifier("sukiru.plugins.manage")
                    .help(
                        "Install plugins or manage configured marketplaces using official host commands"
                    )
            }
            ToolbarItem {
                Picker("Host", selection: $host) {
                    Text("All Hosts").tag(PluginHost?.none)
                    ForEach(PluginHost.allCases, id: \.self) { host in
                        Text(verbatim: host.rawValue).tag(PluginHost?.some(host))
                    }
                }
                .accessibilityIdentifier("sukiru.plugins.host")
                .help("Filter plugin installations by host")
            }
        }
    }

    private func marketplaceRow(_ marketplace: PluginMarketplace) -> some View {
        DisclosureGroup {
            ForEach(marketplace.plugins, id: \.name) { entry in
                HStack {
                    LabeledContent(entry.name, value: entry.version ?? entry.source)
                    Button("Install…") {
                        state.manageCatalogEntry(entry, marketplace: marketplace)
                    }
                    .accessibilityIdentifier("sukiru.plugins.catalog.install.\(entry.name)")
                    .help("Preview installation from this configured marketplace")
                }
            }
        } label: {
            LabeledContent(marketplace.name, value: marketplace.source)
        }
        .accessibilityIdentifier("sukiru.plugins.marketplace.\(marketplace.id)")
        .help("Browse this host's locally configured catalog")
        .contextMenu {
            ForEach(["marketplace-refresh", "marketplace-remove"], id: \.self) { action in
                Button(PluginActionTitle.title(action)) {
                    state.manageMarketplace(marketplace, action: action)
                }
                .accessibilityIdentifier("sukiru.plugins.marketplace.\(action)")
                .help("Preview the official marketplace operation and its full impact")
            }
        }
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
