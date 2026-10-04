import SukiruCore
import SwiftUI

struct PluginManagementSheet: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Manage Host Plugins").font(.title2)
            Form {
                LabeledContent("Host", value: state.pluginManagement.host.displayName)
                    .accessibilityIdentifier("sukiru.plugins.operation.host")
                Picker("Operation", selection: $state.pluginManagement.action) {
                    ForEach(operations, id: \.self) { action in
                        Text(verbatim: PluginActionTitle.title(action)).tag(action)
                    }
                }
                .accessibilityIdentifier("sukiru.plugins.operation.action")
                .help("Unsupported host operations show the host's capability limit")
                TextField(
                    "Plugin, marketplace, package or address", text: $state.pluginManagement.target
                )
                .accessibilityIdentifier("sukiru.plugins.operation.target")
                .help(
                    "Use a host-supported target; * selects all packages for OpenCode list, check or update"
                )
                Picker("Scope", selection: $state.pluginManagement.scopeRoot) {
                    Text("User Library").tag(state.environment.home)
                    ForEach(state.projectRoots, id: \.self) { root in
                        Text(verbatim: root).tag(root)
                    }
                }
                .accessibilityIdentifier("sukiru.plugins.operation.scope")
                .help("Choose user scope or an already-added project")
                .onChange(of: state.pluginManagement.scopeRoot) { _, root in
                    state.pluginManagement.scope =
                        root == state.environment.home ? "user" : "project"
                }
                let isProject = state.pluginManagement.scopeRoot != state.environment.home
                if state.pluginManagement.host == .claude, isProject {
                    Toggle("Local project settings", isOn: localScope)
                        .accessibilityIdentifier("sukiru.plugins.operation.local")
                        .help("Use Claude's local project scope instead of shared project settings")
                }
            }
            Text(
                "plugin.preview.explanation"
            )
            .foregroundStyle(.secondary)
            if let error = state.pluginManagement.error {
                Text(verbatim: error).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { state.pluginManagement.showingSheet = false }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("sukiru.plugins.operation.cancel")
                    .help("Close without creating a command batch")
                Button("Preview in Pending Changes") { state.previewPluginOperation() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        state.pluginManagement.planning || state.pluginManagement.target.isEmpty
                    )
                    .accessibilityIdentifier("sukiru.plugins.operation.preview")
                    .help("Review exact commands, affected files and consequences before execution")
            }
        }
        .padding(20)
        .frame(width: 520)
        .disabled(state.pluginManagement.planning)
    }

    /// The host's own operations, plus a contextual one such as local disable.
    private var operations: [String] {
        let management = state.pluginManagement
        let native = management.host.operations
        return native.contains(management.action) ? native : native + [management.action]
    }

    private var localScope: Binding<Bool> {
        Binding(
            get: { state.pluginManagement.scope == "local" },
            set: { state.pluginManagement.scope = $0 ? "local" : "project" })
    }
}
