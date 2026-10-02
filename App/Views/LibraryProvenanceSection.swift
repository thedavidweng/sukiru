import SukiruCore
import SwiftUI

/// The installer records that claim a skill, shown as plain data; for an
/// ambiguous or capability-blocked skill the notices explain why those
/// records are not acted on.
struct LibraryProvenanceSection: View {
    @EnvironmentObject private var state: AppState

    let skill: Skill

    var body: some View {
        Section {
            if isVercelReadOnly { readOnlyNotice }
            if skill.ambiguous { ambiguousNotice }
            if let vercel = skill.provenance.vercel, !hasCompanionRecord {
                field("Installer", String(localized: "Vercel skills CLI (lock entry)"))
                if let source = vercel.source { field("Source", source) }
                if let ref = vercel.ref { field("Ref", ref) }
                field(
                    "Version",
                    (vercel.updatedAt ?? vercel.installedAt).map(RecordTimestamp.display)
                        ?? String(localized: "unknown"))
            }
            if let github = skill.provenance.github {
                field("Installer", String(localized: "GitHub gh skill (frontmatter)"))
                field("Repository", github.repo)
                if let ref = github.ref { field("Ref", ref) }
                field("Version", github.treeSha ?? String(localized: "unknown"))
                field(
                    "Pin state",
                    github.pinned
                        ? String(localized: "Pinned") : String(localized: "Unpinned"))
                if let update = state.githubUpdate(for: skill) {
                    field(
                        "Update available",
                        [update.availableTree, update.ref.map { "(\($0))" }]
                            .compactMap { $0 }.joined(separator: " "))
                }
            }
            if hasCompanionRecord {
                Text("library.githubCompanionRecord")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let agent = skill.managingAgent {
                Text("library.agentManaged \(agent)")
                    .foregroundStyle(.secondary)
            } else if skill.provenance.vercel == nil && skill.provenance.github == nil {
                Text("No ledger claims this skill (ownerless).")
                    .foregroundStyle(.secondary)
            }
            LibraryLifecycleControls(skill: skill)
        } header: {
            TokenSectionHeader(token: "sukiru.library.detail.provenance", title: "Provenance")
        }
    }

    /// The skill's Vercel lock entry is gh's companion record, not a claim.
    private var hasCompanionRecord: Bool {
        skill.ownership == .github && skill.provenance.vercel?.githubCompanion == true
    }

    private var isVercelReadOnly: Bool {
        guard let caps = state.capabilities, !caps.npx.canRunSkills else { return false }
        return skill.ownership == .vercel || skill.ownership == .doubleBooked
    }

    private var readOnlyNotice: some View {
        // swiftlint:disable line_length
        let hint: LocalizedStringKey =
            "Read-only. Repairing, updating, or uninstalling this skill needs Node.js, which is not installed. Get it in Settings > Installers. Everything else still works."
        // swiftlint:enable line_length
        return HStack(spacing: 0) {
            AXToken(token: "sukiru.library.detail.readonly.\(AXTokens.skill(skill.name))")
            notice(hint)
        }
        .accessibilityElement(children: .contain)
    }

    private var ambiguousNotice: some View {
        // swiftlint:disable line_length
        let explanation: LocalizedStringKey =
            "Ownership ambiguous: distinct copies of this name disagree, so attribution is voided and the skill is treated as ownerless. Ledger claims below are data, not verdicts."
        // swiftlint:enable line_length
        return HStack(spacing: 0) {
            AXToken(token: "sukiru.library.detail.ambiguous.\(AXTokens.skill(skill.name))")
            notice(explanation)
        }
        .accessibilityElement(children: .contain)
    }

    private func notice(_ text: LocalizedStringKey) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        }
    }

    private func field(_ name: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(name) {
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
        }
    }
}
