import SukiruCore
import SwiftUI

/// Library detail pane: provenance (repo, ref, version, pin state), host
/// presence (`sukiru.library.detail.hosts`), the placement list, and the D16
/// deep-link into Health (`sukiru.library.detail.showFindings`). The region
/// carries `sukiru.library.detail` and the provenance block
/// `sukiru.library.detail.provenance`. Provenance values are read straight
/// from the same `ScanReport` the Health surface renders, so the two
/// surfaces can never disagree (VAL-HEALTH-037).
struct LibraryDetailView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let skill = state.selectedSkill() {
            detail(skill)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Select a skill to inspect it")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detail(_ skill: Skill) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AXToken(token: "sukiru.library.detail")
                HStack(spacing: 12) {
                    Text(skill.name)
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button {
                        state.showFindings(for: skill)
                    } label: {
                        Text("Show findings in Health")
                    }
                    .axButtonToken("sukiru.library.detail.showFindings")
                }
                provenanceBlock(skill)
                hostsBlock(skill)
                placementsBlock(skill)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func provenanceBlock(_ skill: Skill) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.library.detail.provenance")
                Text("Provenance")
                    .font(.headline)
            }
            if let vercel = skill.provenance.vercel {
                field("Installer", "Vercel skills CLI (lock entry)")
                if let source = vercel.source {
                    field("Source", source)
                }
                if let ref = vercel.ref {
                    field("Ref", ref)
                }
                field("Version", vercel.updatedAt ?? vercel.installedAt ?? "unknown")
            }
            if let github = skill.provenance.github {
                field("Installer", "GitHub gh skill (frontmatter)")
                field("Repository", github.repo)
                if let ref = github.ref {
                    field("Ref", ref)
                }
                field("Version", github.treeSha ?? "unknown")
                field(
                    "Pin state",
                    github.pinned
                        ? String(localized: "Pinned") : String(localized: "Unpinned"))
            }
            if skill.provenance.vercel == nil && skill.provenance.github == nil {
                Text("No ledger claims this skill (ownerless).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - host presence (VAL-HEALTH-009/010)

    /// One host-workspace row in the host-presence region.
    struct HostEntry: Equatable {
        let workspaceID: String
        let hostID: String
        let displayName: String
        let installed: Bool
    }

    /// Hosts that see this skill: host workspaces whose skills root contains
    /// one of the skill's non-internal placements. The canonical store
    /// (`user` / `project:<root>`) is NOT a host and is never listed. A
    /// leftover workspace (installed=false — CLI spray residue) is reported
    /// as leftover, never as an installed host.
    private func hostEntries(for skill: Skill) -> [HostEntry] {
        guard let report = state.report else { return [] }
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

    private func hostsBlock(_ skill: Skill) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.library.detail.hosts")
                Text("Hosts")
                    .font(.headline)
            }
            if skill.placements.contains(where: \.internal) {
                Text("Internal skill — hidden from host-facing listings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            let entries = hostEntries(for: skill)
            if entries.isEmpty {
                Text("No host sees this skill.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries, id: \.workspaceID) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        AXToken(token: "sukiru.library.detail.host.\(entry.hostID)")
                        Text(entry.displayName)
                            .font(.callout.weight(.medium))
                        if entry.installed {
                            Text("Installed")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Text("Leftover (spray residue — not an install)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
            }
        }
    }

    private func placementsBlock(_ skill: Skill) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Placements")
                .font(.headline)
            ForEach(skill.placements, id: \.path) { placement in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(placement.kind.rawValue)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                    Text(placement.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func field(_ name: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name)
                .font(.callout.weight(.medium))
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
    }
}
