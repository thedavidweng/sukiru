import SukiruCore
import SwiftUI

struct PluginDetailView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if let plugin = state.selectedPlugin {
                Form {
                    Section {
                        LabeledContent("Host", value: plugin.host.displayName)
                        if let format = plugin.format {
                            LabeledContent(
                                "Format",
                                value: format == "agent-plugin"
                                    ? String(localized: "Agent Plugin")
                                    : String(localized: "Cursor Plugin"))
                        }
                        LabeledContent("Source", value: plugin.sourceTitle)
                        LabeledContent(
                            "Scope",
                            value: plugin.scopeRoot == state.environment.home
                                ? String(localized: "User Library") : plugin.scopeRoot)
                        LabeledContent(
                            "Version", value: plugin.version ?? String(localized: "Unknown"))
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
                        LabeledContent("Runtime", value: String(localized: "Not Checked"))
                    } header: {
                        Text(verbatim: plugin.displayName)
                            .font(.title.weight(.semibold))
                            .textCase(nil)
                            .foregroundStyle(.primary)
                            .padding(.bottom, 8)
                    }
                    if !plugin.components.isEmpty {
                        Section("Components") {
                            ForEach(Array(plugin.components.enumerated()), id: \.offset) { entry in
                                LabeledContent(entry.element.name, value: entry.element.kind)
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
        ToolbarItemGroup {
            Button {
                state.revealInFinder(paths)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .disabled(paths.isEmpty)
            .accessibilityIdentifier("sukiru.plugins.reveal")
            .help("Show the plugin's recorded path in Finder")
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
