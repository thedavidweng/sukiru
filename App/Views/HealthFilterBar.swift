import SukiruCore
import SwiftUI

/// The Health workspace filter bar (VAL-HEALTH-015/047): one option per
/// report workspace (plus "All"), each showing its finding count so a
/// zero-finding workspace is visible and selectable. The bar carries the
/// `sukiru.health.filter.workspace` token; each option button carries
/// `sukiru.health.filter.workspace.<sanitized-id>`.
struct HealthFilterBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            AXToken(token: "sukiru.health.filter.workspace")
            Text("Workspace")
                .font(.callout.weight(.medium))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    optionButton(
                        token: "sukiru.health.filter.workspace.all",
                        title: String(localized: "All"),
                        count: state.visibleHealthEntriesIgnoringWorkspaceFilter().count,
                        selected: state.healthWorkspaceFilter == nil
                    ) {
                        state.healthWorkspaceFilter = nil
                    }
                    ForEach(state.workspaceFilterOptions(), id: \.workspace.id) { option in
                        let segment = AXTokens.path(option.workspace.id)
                        optionButton(
                            token: "sukiru.health.filter.workspace.\(segment)",
                            title: title(for: option.workspace),
                            count: option.count,
                            selected: state.healthWorkspaceFilter == option.workspace.id
                        ) {
                            state.healthWorkspaceFilter = option.workspace.id
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func optionButton(
        token: String, title: String, count: Int, selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let label = Text("\(title) (\(count))")
            .font(.caption.weight(.medium))
        if selected {
            Button(action: action) { label }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .axButtonToken(token)
        } else {
            Button(action: action) { label }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .axButtonToken(token)
        }
    }

    /// Human-readable option names: the user scope, hosts by display name
    /// (leftover spray residue marked, never presented as installed), and
    /// project roots by directory name.
    private func title(for workspace: Workspace) -> String {
        if workspace.id == "user" {
            return String(localized: "User scope")
        }
        if workspace.id.hasPrefix("host:") {
            let hostID = String(workspace.id.dropFirst("host:".count))
            let name = HostTable.host(id: hostID)?.displayName ?? hostID
            if workspace.installed {
                return name
            }
            return "\(name) (\(String(localized: "leftover")))"
        }
        if workspace.id.hasPrefix("project:") {
            let root = String(workspace.id.dropFirst("project:".count))
            return URL(fileURLWithPath: root).lastPathComponent
        }
        return workspace.id
    }
}

/// Banner shown while the Health surface is focused on one skill by the
/// Library "show findings" deep-link (D16, VAL-CROSS-005).
struct HealthFocusBanner: View {
    @EnvironmentObject private var state: AppState
    let focus: AppState.HealthFocus

    /// `user` or `project:<root>`, shown as "User scope" or the project
    /// folder.
    private var scopeLabel: String {
        guard focus.scopeGroup.hasPrefix("project:") else {
            return String(localized: "User scope")
        }
        let root = String(focus.scopeGroup.dropFirst("project:".count))
        return (root as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        HStack(spacing: 8) {
            AXToken(token: "sukiru.health.focus")
            Text("Findings for \(focus.skillName)")
                .font(.callout.weight(.medium))
            Text(verbatim: scopeLabel)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                state.clearHealthFocus()
            } label: {
                Text("Show All")
            }
            .axButtonToken("sukiru.health.showAll")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
