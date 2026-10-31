import SukiruCore
import SwiftUI

/// The host-presence section of the Library detail pane,
/// carrying `sukiru.library.detail.hosts` on its header and
/// `sukiru.library.detail.host.<hostID>` on each row.
struct LibraryHostsSection: View {
    let skill: Skill
    let entries: [HostEntry]

    /// One agent that can read a scanned skills workspace.
    struct HostEntry: Equatable {
        let workspaceID: String
        let hostID: String
        let displayName: String
        let installed: Bool
    }

    var body: some View {
        let installed = entries.filter(\.installed)
        let leftovers = entries.filter { !$0.installed }
        Section {
            if skill.placements.contains(where: \.internal) {
                Text("Internal skill, hidden from host-facing listings.")
                    .foregroundStyle(.secondary)
            }
            if entries.isEmpty {
                Text("No host sees this skill.")
                    .foregroundStyle(.secondary)
            }
            if !installed.isEmpty {
                grid(installed)
            }
            // Copies in folders of agents that are not installed are never
            // read; folding them away keeps the agents that really read the
            // skill in front.
            if !leftovers.isEmpty {
                DisclosureGroup {
                    grid(leftovers)
                } label: {
                    Text("Agents not installed on this Mac")
                        .foregroundStyle(.secondary)
                        .badge(leftovers.count)
                }
            }
        } header: {
            TokenSectionHeader(
                token: "sukiru.library.detail.hosts", title: "Hosts",
                count: installed.isEmpty ? nil : installed.count
            )
        }
    }

    private func grid(_ entries: [HostEntry]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .leading)],
            alignment: .leading, spacing: 10
        ) {
            ForEach(entries, id: \.workspaceID) { entry in
                cell(entry)
            }
        }
        .padding(.vertical, 4)
    }

    private func cell(_ entry: HostEntry) -> some View {
        HStack(spacing: 8) {
            Color.clear
                .frame(width: 16, height: 16)
                .overlay { AgentLogo(hostID: entry.hostID, size: 16) }
            HStack(spacing: 0) {
                AXToken(token: "sukiru.library.detail.host.\(entry.hostID)")
                Text(entry.displayName)
                    .lineLimit(1)
                    .foregroundStyle(entry.installed ? .primary : .secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

}

extension AppState {
    /// Every agent whose configured skills root holds one of the skill's
    /// placements. A shared root may serve several agents even though the
    /// scan reports only one workspace for that physical directory. Resolved
    /// once per report: list rows ask on every render.
    func hostEntries(for skill: Skill) -> [LibraryHostsSection.HostEntry] {
        if derived.hostEntries?.reportRevision != reportRevision {
            derived.hostEntries = HostEntryCache(reportRevision: reportRevision)
        }
        let id = Self.skillID(skill)
        if let cached = derived.hostEntries?.entries[id] { return cached }
        guard let report else { return [] }
        let scopeRoot = skill.scope == .user ? nil : projectRoot(of: skill)
        let hostsByRoot = hostsByRoot(projectRoot: scopeRoot)
        var entries: [LibraryHostsSection.HostEntry] = []
        if skill.scope == .user || scopeRoot != nil {
            for placement in skill.placements where !placement.internal {
                for workspace in report.workspaces {
                    let prefix =
                        workspace.root.hasSuffix("/") ? workspace.root : workspace.root + "/"
                    guard placement.path == workspace.root || placement.path.hasPrefix(prefix)
                    else {
                        continue
                    }
                    for host in hostsByRoot[workspace.root] ?? [] {
                        let entry = LibraryHostsSection.HostEntry(
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
        }
        entries.sort {
            $0.displayName == $1.displayName
                ? $0.workspaceID < $1.workspaceID
                : $0.displayName < $1.displayName
        }
        derived.hostEntries?.entries[id] = entries
        return entries
    }

    /// Hosts by each skills root they read in user scope (nil) or one project.
    private func hostsByRoot(projectRoot: String?) -> [String: [HostSpec]] {
        let key = projectRoot ?? ""
        if let cached = derived.hostEntries?.roots[key] { return cached }
        let resolver = HostPathResolver(
            environment: environment, fileSystem: DefaultFileSystemProbe())
        var table: [String: [HostSpec]] = [:]
        for host in HostTable.hosts {
            let roots =
                if let projectRoot {
                    [resolver.projectSkillsRoot(for: host, projectRoot: projectRoot)]
                        + resolver.legacyProjectSkillsRoots(for: host, projectRoot: projectRoot)
                } else {
                    [resolver.globalSkillsRoot(for: host)]
                        + resolver.legacyGlobalSkillsRoots(for: host)
                }
            for root in Set(roots) { table[root, default: []].append(host) }
        }
        derived.hostEntries?.roots[key] = table
        return table
    }
}
