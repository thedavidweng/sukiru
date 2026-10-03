import SukiruCore
import SwiftUI

struct PluginDetailView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let plugin = state.selectedPlugin {
            Form {
                Section {
                    LabeledContent("Host", value: plugin.host.rawValue)
                    LabeledContent("Source", value: plugin.source)
                    LabeledContent("Scope", value: plugin.scopeRoot)
                    LabeledContent("Version", value: plugin.version ?? String(localized: "Unknown"))
                    LabeledContent("Installation", value: plugin.localizedInstallationStatus)
                    LabeledContent("Configured Enablement", value: plugin.enablement.localizedTitle)
                    LabeledContent("Load Status", value: String(localized: "Unknown"))
                    Text(
                        "Configured enablement does not establish that a host session loaded this plugin."
                    )
                    .foregroundStyle(.secondary)
                } header: {
                    Text(verbatim: plugin.identifier)
                }
                Section("Components") {
                    ForEach(Array(plugin.components.enumerated()), id: \.offset) { _, component in
                        LabeledContent(component.name, value: component.kind)
                    }
                    Text("Components follow the host's plugin management granularity.")
                        .foregroundStyle(.secondary)
                }
                if let findings = state.report?.pluginInventory?.healthFindings.filter({
                    $0.pluginID == plugin.id
                }), !findings.isEmpty {
                    PluginHealthSection(findings: findings)
                }
            }
            .formStyle(.grouped)
            .textSelection(.enabled)
            .toolbar {
                ToolbarItem {
                    Menu("Manage Plugin") {
                        ForEach(
                            ["enable", "disable", "update", "remove", "disable-local"], id: \.self
                        ) { action in
                            Button(PluginActionTitle.title(action)) {
                                state.managePlugin(plugin, action: action)
                            }
                            .accessibilityIdentifier("sukiru.plugins.action.\(action)")
                            .help("Preview this host's supported operation or capability limit")
                        }
                    }
                    .accessibilityIdentifier("sukiru.plugins.actions")
                    .help("Review plugin lifecycle changes before running them")
                }
                ToolbarItem {
                    Button("Show in Finder") {
                        if let path = plugin.path { state.revealInFinder([path]) }
                    }
                    .disabled(plugin.path == nil)
                    .accessibilityIdentifier("sukiru.plugins.reveal")
                    .help("Show the plugin's recorded path in Finder")
                }
            }
        } else {
            ContentUnavailableView(
                "Select a plugin to inspect it", systemImage: "puzzlepiece.extension")
        }
    }
}
