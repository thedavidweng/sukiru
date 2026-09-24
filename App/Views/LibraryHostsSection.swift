import SukiruCore
import SwiftUI

/// The host-presence section of the Library detail pane (VAL-HEALTH-009/010),
/// carrying `sukiru.library.detail.hosts` on its header and
/// `sukiru.library.detail.host.<hostID>` on each row.
struct LibraryHostsSection: View {
    let skill: Skill
    let report: ScanReport?

    /// One host-workspace row in the host-presence region.
    struct HostEntry: Equatable {
        let workspaceID: String
        let hostID: String
        let displayName: String
        let installed: Bool
    }

    var body: some View {
        let entries = hostEntries()
        Section {
            if skill.placements.contains(where: \.internal) {
                Text("Internal skill — hidden from host-facing listings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if entries.isEmpty {
                Text("No host sees this skill.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries, id: \.workspaceID) { entry in
                    row(entry)
                }
            }
        } header: {
            TokenSectionHeader(
                token: "sukiru.library.detail.hosts", title: "Hosts",
                count: entries.isEmpty ? nil : entries.count)
        }
    }

    private func row(_ entry: HostEntry) -> some View {
        LabeledContent {
            if entry.installed {
                Text("Installed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Leftover (spray residue — not an install)")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        } label: {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.library.detail.host.\(entry.hostID)")
                Text(entry.displayName)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Hosts that see this skill: host workspaces whose skills root contains
    /// one of the skill's non-internal placements. The canonical store
    /// (`user` / `project:<root>`) is NOT a host and is never listed. A
    /// leftover workspace (installed=false — CLI spray residue) is reported
    /// as leftover, never as an installed host.
    private func hostEntries() -> [HostEntry] {
        guard let report else { return [] }
        var entries: [HostEntry] = []
        for placement in skill.placements where !placement.internal {
            for workspace in report.workspaces {
                guard let hostID = Self.hostID(of: workspace.id) else { continue }
                let prefix = workspace.root.hasSuffix("/") ? workspace.root : workspace.root + "/"
                guard placement.path == workspace.root || placement.path.hasPrefix(prefix) else {
                    continue
                }
                let entry = HostEntry(
                    workspaceID: workspace.id,
                    hostID: hostID,
                    displayName: HostTable.host(id: hostID)?.displayName ?? hostID,
                    installed: workspace.installed)
                if !entries.contains(entry) {
                    entries.append(entry)
                }
            }
        }
        return entries.sorted {
            $0.displayName == $1.displayName
                ? $0.workspaceID < $1.workspaceID
                : $0.displayName < $1.displayName
        }
    }

    /// Extracts the host id from a host workspace id (`host:<id>` user scope,
    /// `project:<root>#<id>` project scope); nil for canonical stores.
    private static func hostID(of workspaceID: String) -> String? {
        if workspaceID.hasPrefix("host:") {
            return String(workspaceID.dropFirst("host:".count))
        }
        if let hash = workspaceID.lastIndex(of: "#") {
            return String(workspaceID[workspaceID.index(after: hash)...])
        }
        return nil
    }
}
