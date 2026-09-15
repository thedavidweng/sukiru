import SukiruCore
import SwiftUI

/// Library detail pane: provenance (repo, ref, version, pin state) and the
/// placement list for the selected skill. The region carries
/// `sukiru.library.detail` and the provenance block
/// `sukiru.library.detail.provenance`.
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
                Text(skill.name)
                    .font(.title2.weight(.semibold))
                provenanceBlock(skill)
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
