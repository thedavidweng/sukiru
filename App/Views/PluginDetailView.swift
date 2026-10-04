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
                        LabeledContent("Source", value: plugin.sourceTitle)
                        LabeledContent(
                            "Scope",
                            value: plugin.scopeRoot == state.environment.home
                                ? String(localized: "User Library") : plugin.scopeRoot)
                        LabeledContent(
                            "Version", value: plugin.version ?? String(localized: "Unknown"))
                        if plugin.offersEnabledToggle {
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
            } else {
                ContentUnavailableView(
                    "Select a plugin to inspect it", systemImage: "puzzlepiece.extension")
            }
        }
        .toolbar(content: toolbar)
    }

    @ToolbarContentBuilder
    private func toolbar() -> some ToolbarContent {
        let plugin = state.selectedPlugin
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }
        ToolbarItem {
            Button {
                if let path = plugin?.path { state.revealInFinder([path]) }
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .disabled(plugin?.path == nil)
            .accessibilityIdentifier("sukiru.plugins.reveal")
            .help("Show the plugin's recorded path in Finder")
        }
    }

    /// Lifecycle actions as plain buttons at the end of the form, removal
    /// last, like a Passwords entry. Each opens a reviewed preview.
    @ViewBuilder
    private func actionsSection(_ plugin: PluginInstallation) -> some View {
        let actions =
            plugin.secondaryActions + (plugin.actions.contains("remove") ? ["remove"] : [])
        if !actions.isEmpty {
            Section {
                HStack {
                    Spacer()
                    ForEach(actions, id: \.self) { action in
                        Button(
                            PluginActionTitle.title(action) + "…",
                            role: action == "remove" ? .destructive : nil
                        ) {
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
