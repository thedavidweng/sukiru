import SukiruCore
import SwiftUI

struct LibraryOverviewView: View {
    @EnvironmentObject private var state: AppState

    let skill: Skill

    private var hostCount: Int {
        LibraryHostsSection(
            skill: skill, report: state.report, environment: state.environment,
            projectRoot: state.projectRoot(of: skill)
        )
        .hostEntries().filter(\.installed).count
    }

    private var findingCount: Int { state.findings(for: skill).count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 28) {
                    metric("Hosts", value: hostCount)
                    metric("Placements", value: skill.placements.count)
                    metric("Findings", value: findingCount)
                }
                Divider()
                if isVercelReadOnly { readOnlyNotice }
                if skill.ambiguous { ambiguousNotice }
                if findingCount > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("\(findingCount) findings", systemImage: "exclamationmark.circle")
                            .font(.headline)
                        Text("Review the evidence and installer record before planning a repair.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                }
                provenance
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metric(_ title: LocalizedStringKey, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value, format: .number)
                .font(.title2.monospacedDigit())
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isVercelReadOnly: Bool {
        guard let caps = state.capabilities, !caps.npx.resolvable else { return false }
        return skill.ownership == .vercel || skill.ownership == .doubleBooked
    }

    private var readOnlyNotice: some View {
        // swiftlint:disable line_length
        let hint: LocalizedStringKey =
            "Read-only — repairing or updating this skill needs Node.js (npx skills), which is not available. Everything else still works."
        // swiftlint:enable line_length
        return HStack(spacing: 0) {
            AXToken(token: "sukiru.library.detail.readonly.\(AXTokens.skill(skill.name))")
            Label(hint, systemImage: "exclamationmark.triangle")
                .font(.callout)
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
            Label(explanation, systemImage: "exclamationmark.triangle")
                .font(.callout)
        }
        .accessibilityElement(children: .contain)
    }

    private var provenance: some View {
        VStack(alignment: .leading, spacing: 11) {
            TokenSectionHeader(
                token: "sukiru.library.detail.provenance", title: "Provenance"
            )
            .font(.headline)
            if let vercel = skill.provenance.vercel {
                field("Installer", String(localized: "Vercel skills CLI (lock entry)"))
                if let source = vercel.source { field("Source", source) }
                if let ref = vercel.ref { field("Ref", ref) }
                field(
                    "Version",
                    vercel.updatedAt ?? vercel.installedAt ?? String(localized: "unknown"))
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
            }
            if skill.provenance.vercel == nil && skill.provenance.github == nil {
                Text("No ledger claims this skill (ownerless).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func field(_ name: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(name)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}
