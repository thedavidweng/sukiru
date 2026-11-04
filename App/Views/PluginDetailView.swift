import SukiruCore
import SwiftUI

struct PluginDetailView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if state.showsPluginMarketplace && state.pluginHost.hasMarketplaceBrowser {
            PluginCatalogDetailView()
        } else {
            installationDetail
        }
    }

    private var installationDetail: some View {
        Group {
            if let plugin = state.selectedPlugin {
                let listing = state.pluginListing(for: plugin)
                Form {
                    Section {
                        if let summary = plugin.summary {
                            Text(verbatim: summary)
                        }
                        LabeledContent("Host", value: plugin.host.displayName)
                        if let format = plugin.format {
                            LabeledContent(
                                "Format",
                                value: format == "agent-plugin"
                                    ? String(localized: "Agent Plugin")
                                    : String(localized: "Cursor Plugin"))
                        }
                        if let source = plugin.sourceTitle {
                            LabeledContent("Source", value: source)
                        }
                        LabeledContent("Scope") {
                            Text(verbatim: scopeValue(plugin))
                                .help(plugin.scopeRoot)
                        }
                        if let version = plugin.version {
                            LabeledContent("Version", value: version)
                        }
                        if plugin.offersEnabledSwitch {
                            PluginEnabledToggle(plugin: plugin)
                        } else {
                            LabeledContent(
                                "Enabled in Host", value: plugin.enablement.localizedTitle
                            )
                            .help(
                                "This is the host's configured state; runtime loading has not been checked."
                            )
                        }
                    } header: {
                        HStack(spacing: 12) {
                            PluginLogo(address: listing?.logo ?? plugin.logo, size: 40)
                            Text(verbatim: listing?.title ?? plugin.displayName)
                                .font(.title.weight(.semibold))
                        }
                        .textCase(nil)
                        .foregroundStyle(.primary)
                        .padding(.bottom, 8)
                    }
                    if !plugin.components.isEmpty {
                        Section("Components") {
                            ForEach(Array(plugin.components.enumerated()), id: \.offset) { entry in
                                LabeledContent(
                                    entry.element.name, value: entry.element.localizedKind)
                            }
                        }
                    }
                    Section {
                        DisclosureGroup("Locations") {
                            LabeledContent("Identifier", value: plugin.identifier)
                            LabeledContent(
                                "Installation", value: plugin.localizedInstallationStatus)
                            if let path = plugin.path {
                                LabeledContent("Path") {
                                    Text(verbatim: path)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(path)
                                }
                            }
                        }
                        .accessibilityIdentifier("sukiru.plugins.locations")
                        .help("Inspect the plugin identifier and recorded path")
                    }
                    if let findings = state.report?.pluginInventory?.healthFindings.filter({
                        $0.pluginID == plugin.id
                    }), !findings.isEmpty {
                        PluginHealthSection(findings: findings)
                    }
                    if plugin.host == .antigravity {
                        Section("Manage in Antigravity") {
                            Text(
                                """
                                Use Customizations or /plugins for marketplace search, automatic updates, \
                                project registration, MCP configuration and authentication, sidecars, \
                                and context providers. Built-in and external plugin sources stay in the host’s control.
                                """
                            )
                            .foregroundStyle(.secondary)
                            Link(
                                "Antigravity Plugin Guide",
                                destination: URL(
                                    string: "https://antigravity.google/docs/plugins/")!
                            )
                            .accessibilityIdentifier("sukiru.plugins.antigravity.guide")
                            .help("Open the official Antigravity plugin management guide")
                        }
                    }
                    if plugin.host == .droid {
                        Section("Manage in Droid") {
                            Text(
                                """
                                Use /plugins in Droid for marketplace auto-update and plugin \
                                details. Organization plugins and marketplaces follow org \
                                settings, and Droid installs them when it starts.
                                """
                            )
                            .foregroundStyle(.secondary)
                            Link(
                                "Droid Plugin Guide",
                                destination: URL(
                                    string: "https://docs.factory.com/harness/plugins")!
                            )
                            .accessibilityIdentifier("sukiru.plugins.droid.guide")
                            .help("Open the official Droid plugin guide")
                        }
                    }
                    actionsSection(plugin)
                }
                .formStyle(.grouped)
                .textSelection(.enabled)
            } else if state.selectedPluginIDs.count > 1 {
                ContentUnavailableView(
                    "\(state.selectedPluginIDs.count) Plugins Selected",
                    systemImage: "puzzlepiece.extension")
            } else {
                ContentUnavailableView(
                    "Select a plugin to inspect it", systemImage: "puzzlepiece.extension")
            }
        }
        .toolbar(content: toolbar)
    }

    private let updateHelp: LocalizedStringKey = "Preview the host's update command for this plugin"

    /// User and organization settings have names; a project scope is its folder.
    private func scopeValue(_ plugin: PluginInstallation) -> String {
        switch plugin.scope {
        case "user": String(localized: "User scope")
        case "org": String(localized: "Organization settings")
        default: URL(fileURLWithPath: plugin.scopeRoot).lastPathComponent
        }
    }

    /// Finder-style item actions beside the inspector, each a standard
    /// toolbar button that previews its command before anything runs. They
    /// stay in place and dim when the selection does not support them.
    @ToolbarContentBuilder
    private func toolbar() -> some ToolbarContent {
        let plugins = state.selectedPlugins
        let single = state.selectedPlugin
        let paths = plugins.compactMap(\.path)
        let removable = plugins.filter { $0.actions.contains("remove") }
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }
        ColumnAction {
            Button {
                state.revealInFinder(paths)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .disabled(paths.isEmpty)
            .accessibilityIdentifier("sukiru.plugins.reveal")
            .help("Show the plugin's recorded path in Finder")
        }
        ColumnAction {
            Button {
                if let single { state.managePlugin(single, action: "update") }
            } label: {
                Label(
                    PluginActionTitle.title("update"),
                    systemImage: PluginActionTitle.symbol("update"))
            }
            .disabled(
                state.pluginActionsBusy || single?.actions.contains("update") != true
            )
            .accessibilityIdentifier("sukiru.plugins.action.update")
            .help(
                single.map { $0.actions.contains("update") ? updateHelp : $0.noUpdateReason }
                    ?? updateHelp)
        }
        ColumnAction {
            Button(role: .destructive) {
                state.removePlugins(removable)
            } label: {
                Label(
                    PluginActionTitle.title("remove"),
                    systemImage: PluginActionTitle.symbol("remove"))
            }
            .disabled(state.pluginActionsBusy || removable.isEmpty)
            .accessibilityIdentifier("sukiru.plugins.action.remove")
            .help("Preview removing the selected plugins")
        }
    }

    /// Less frequent lifecycle actions as plain buttons at the end of the
    /// form, like a Passwords entry. Each opens a reviewed preview.
    @ViewBuilder
    private func actionsSection(_ plugin: PluginInstallation) -> some View {
        if !plugin.secondaryActions.isEmpty {
            Section {
                HStack {
                    Spacer()
                    ForEach(plugin.secondaryActions, id: \.self) { action in
                        Button(PluginActionTitle.title(action) + "…") {
                            state.managePlugin(plugin, action: action)
                        }
                        .accessibilityIdentifier("sukiru.plugins.action.\(action)")
                        .help("Preview this host's supported operation or capability limit")
                    }
                }
                .disabled(state.pluginActionsBusy)
            }
        }
    }
}
