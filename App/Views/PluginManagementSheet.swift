import SukiruCore
import SwiftUI

struct PluginManagementSheet: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if state.pluginManagement.repositoryInstall {
                Text("Install from Repository").font(.title2)
            } else {
                Text("Manage Host Plugins").font(.title2)
            }
            Form {
                LabeledContent("Host", value: state.pluginManagement.host.displayName)
                    .accessibilityIdentifier("sukiru.plugins.operation.host")
                if state.pluginManagement.repositoryInstall {
                    repositoryFields
                } else {
                    operationFields
                }
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

    @ViewBuilder
    private var operationFields: some View {
        Picker("Operation", selection: $state.pluginManagement.action) {
            ForEach(operations, id: \.self) { action in
                Text(verbatim: PluginActionTitle.title(action)).tag(action)
            }
        }
        .accessibilityIdentifier("sukiru.plugins.operation.action")
        .help("Unsupported host operations show the host's capability limit")
        .onChange(of: state.pluginManagement.action) { _, action in
            state.pluginManagement.target = ["list", "import"].contains(action) ? "*" : ""
        }
        TextField(
            "Plugin, marketplace, package or address", text: $state.pluginManagement.target
        )
        .accessibilityIdentifier("sukiru.plugins.operation.target")
        .help(
            "Use a host-supported target; * selects all packages for OpenCode list, check or update"
        )
        if state.pluginManagement.host == .antigravity {
            antigravityOptions
        }
        let showsGitRef =
            state.pluginManagement.host == .cursor
            && state.pluginManagement.action == "marketplace-add"
        if showsGitRef {
            TextField("Git ref (optional)", text: gitRef)
                .accessibilityIdentifier("sukiru.plugins.operation.git-ref")
                .help("Pass one Cursor-supported branch, tag, or commit ref")
        }
    }

    @ViewBuilder
    private var repositoryFields: some View {
        TextField("owner/repo or GitHub URL", text: $state.pluginManagement.target)
            .accessibilityIdentifier("sukiru.plugins.operation.repository")
            .help("A GitHub repository that contains an Antigravity plugin")
        Text(
            """
            agy clones the repository's default branch. \
            This is not a marketplace listing, so its contents can differ from a marketplace version.
            """
        )
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var antigravityOptions: some View {
        if state.pluginManagement.action == "link" {
            TextField("Marketplace", text: $state.pluginManagement.marketplace)
                .accessibilityIdentifier("sukiru.plugins.operation.marketplace")
                .help("Pass the marketplace argument to agy plugin link")
        }
        if state.pluginManagement.action == "validate" {
            Toggle("Fail on validation warnings", isOn: $state.pluginManagement.strict)
                .accessibilityIdentifier("sukiru.plugins.operation.strict")
                .help("Run native validation with --strict")
        }
        Text(
            """
            Antigravity uses shared enablement across scopes. \
            Install accepts plugin@marketplace or a local directory path. \
            Import accepts gemini, claude, or * for both sources. Validate accepts a path; list uses *.
            """
        )
        .foregroundStyle(.secondary)
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

    private var gitRef: Binding<String> {
        Binding(
            get: { state.pluginManagement.gitRef ?? "" },
            set: { state.pluginManagement.gitRef = $0.isEmpty ? nil : $0 })
    }
}
