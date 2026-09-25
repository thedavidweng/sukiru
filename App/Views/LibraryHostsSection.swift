import SukiruCore
import SwiftUI

/// The host-presence section of the Library detail pane (VAL-HEALTH-009/010),
/// carrying `sukiru.library.detail.hosts` on its header and
/// `sukiru.library.detail.host.<hostID>` on each row.
struct LibraryHostsSection: View {
    let skill: Skill
    let report: ScanReport?
    let environment: SukiruEnvironment
    let projectRoot: String?

    /// One agent that can read a scanned skills workspace.
    struct HostEntry: Equatable {
        let workspaceID: String
        let hostID: String
        let displayName: String
        let installed: Bool
    }

    var body: some View {
        let entries = hostEntries()
        VStack(alignment: .leading, spacing: 12) {
            TokenSectionHeader(
                token: "sukiru.library.detail.hosts", title: "Hosts",
                count: entries.isEmpty ? nil : entries.count
            )
            .font(.headline)
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
        }
    }

    private func row(_ entry: HostEntry) -> some View {
        HStack(spacing: 10) {
            AgentLogo(hostID: entry.hostID)
            HStack(spacing: 0) {
                AXToken(token: "sukiru.library.detail.host.\(entry.hostID)")
                Text(entry.displayName)
            }
            Spacer(minLength: 12)
            if entry.installed {
                Text("Installed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Leftover (spray residue — not an install)")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Match every agent's configured skills root against scanned placements.
    /// A shared root may serve several agents even though the scan reports
    /// only one workspace for that physical directory.
    func hostEntries() -> [HostEntry] {
        guard let report else { return [] }
        let resolver = HostPathResolver(
            environment: environment, fileSystem: DefaultFileSystemProbe())
        var entries: [HostEntry] = []
        for placement in skill.placements where !placement.internal {
            for workspace in report.workspaces {
                let prefix = workspace.root.hasSuffix("/") ? workspace.root : workspace.root + "/"
                guard placement.path == workspace.root || placement.path.hasPrefix(prefix) else {
                    continue
                }
                for host in HostTable.hosts {
                    let root: String
                    if skill.scope == .user {
                        root = resolver.globalSkillsRoot(for: host)
                    } else if let projectRoot {
                        root = resolver.projectSkillsRoot(for: host, projectRoot: projectRoot)
                    } else {
                        continue
                    }
                    guard root == workspace.root else { continue }
                    let entry = HostEntry(
                        workspaceID: "\(workspace.id)#\(host.id)",
                        hostID: host.id,
                        displayName: host.displayName,
                        installed: workspace.installed)
                    if !entries.contains(entry) {
                        entries.append(entry)
                    }
                }
            }
        }
        return entries.sorted {
            $0.displayName == $1.displayName
                ? $0.workspaceID < $1.workspaceID
                : $0.displayName < $1.displayName
        }
    }

}
