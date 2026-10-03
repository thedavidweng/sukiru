import SukiruCore
import SwiftUI

struct PluginHealthSection: View {
    @EnvironmentObject private var state: AppState
    let findings: [PluginHealthFinding]

    var body: some View {
        Section("Plugin Compatibility") {
            ForEach(findings) { finding in
                DisclosureGroup {
                    Text("plugin.health.v1Definition")
                    Text(verbatim: finding.path)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    if !finding.historicalEvidence.isEmpty {
                        Text("Historical Load Errors")
                            .font(.headline)
                        Text("Historical errors do not establish a current runtime failure.")
                            .foregroundStyle(.secondary)
                        ForEach(finding.historicalEvidence, id: \.self) { line in
                            Text(verbatim: line).textSelection(.enabled)
                        }
                    }
                    Link(
                        "Producer Migration Instructions",
                        destination: URL(string: PluginLocalDisable.migrationURL)!)
                    if let plugin = state.report?.pluginInventory?.installations.first(where: {
                        $0.id == finding.pluginID
                    }) {
                        Button("Preview Local Disable…") {
                            state.managePlugin(plugin, action: "disable-local")
                        }
                        .accessibilityIdentifier("sukiru.plugins.health.disable.\(finding.id)")
                        .help(
                            "Check the host version and preview a protected move outside discovery")
                    }
                } label: {
                    Label("Legacy Plugin Definition", systemImage: "exclamationmark.triangle")
                }
                .accessibilityIdentifier("sukiru.plugins.health.\(finding.id)")
            }
        }
    }
}

extension AppState {
    var visiblePluginFindings: [PluginHealthFinding] {
        guard healthFocus == nil else { return [] }
        return (report?.pluginInventory?.healthFindings ?? []).filter { finding in
            guard let filter = healthWorkspaceFilter else { return true }
            let scope =
                finding.scopeRoot == environment.home ? "user" : "project:\(finding.scopeRoot)"
            return filter == scope
        }
    }
}
