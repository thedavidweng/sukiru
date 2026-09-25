import SukiruCore
import SwiftUI

/// Library detail pane: provenance (repo, ref, version, pin state), host
/// presence (`sukiru.library.detail.hosts`), the placement list, and the D16
/// deep-link into Health (`sukiru.library.detail.showFindings`). The region
/// carries `sukiru.library.detail` and the provenance block
/// `sukiru.library.detail.provenance`. Provenance values are read straight
/// from the same `ScanReport` the Health surface renders, so the two
/// surfaces can never disagree (VAL-HEALTH-037).
///
/// Layout is a grouped `Form` — the same construction System Settings uses —
/// so section grouping, row insets, and label alignment come from the system
/// rather than from hand-tuned padding (ADR-0006).
struct LibraryDetailView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedTab: DetailTab = .overview

    private enum DetailTab: String, CaseIterable {
        case overview
        case content
        case locations

        var title: LocalizedStringKey {
            switch self {
            case .overview: "Overview"
            case .content: "Content"
            case .locations: "Locations"
            }
        }
    }

    var body: some View {
        if let skill = state.selectedSkill() {
            detail(skill)
        } else {
            ContentUnavailableView {
                Label("Select a skill to inspect it", systemImage: "doc.text.magnifyingglass")
            }
        }
    }

    private func detail(_ skill: Skill) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                headerRow(skill)
                if let description = state.skillDescriptions[skill.selfID] {
                    Text(description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                actionRow(skill)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            Picker("Skill detail", selection: $selectedTab) {
                ForEach(DetailTab.allCases, id: \.self) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            switch selectedTab {
            case .overview:
                overview(skill)
            case .content:
                SkillContentView(skill: skill)
            case .locations:
                Form {
                    LibraryHostsSection(skill: skill, report: state.report)
                    placementsSection(skill)
                }
                .formStyle(.grouped)
            }
        }
        .onChange(of: skill.selfID) { _, _ in selectedTab = .overview }
    }

    private func overview(_ skill: Skill) -> some View {
        Form {
            Section("Status") {
                LabeledContent("Hosts") {
                    Text(
                        LibraryHostsSection(skill: skill, report: state.report)
                            .hostEntries().filter(\.installed).count,
                        format: .number)
                }
                LabeledContent("Placements") {
                    Text(skill.placements.count, format: .number)
                }
                LabeledContent("Findings") {
                    Text(state.findings(for: skill).count, format: .number)
                }
                if isVercelReadOnly(skill) { readOnlyNotice(skill) }
                if skill.ambiguous { ambiguousNotice(skill) }
            }
            provenanceSection(skill)
            let findingCount = state.findings(for: skill).count
            if findingCount > 0 {
                Section("Needs attention") {
                    Label("\(findingCount) findings", systemImage: "exclamationmark.circle")
                    Text("Review the evidence and installer record before planning a repair.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Inspect findings") {
                        state.showFindings(for: skill)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - header

    private func headerRow(_ skill: Skill) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.library.detail")
                Text(skill.name)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                Text(ownershipText(skill))
                Text(verbatim: "·")
                scopeText(skill)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionRow(_ skill: Skill) -> some View {
        HStack(spacing: 8) {
            Button {
                state.quickLookSelectedSkill()
            } label: {
                Label("Quick Look SKILL.md", systemImage: "eye")
            }
            .buttonStyle(.borderedProminent)
            .axButtonToken(
                "sukiru.library.quicklook",
                disabled: state.skillMarkdownURL(for: skill) == nil
            )
            .disabled(state.skillMarkdownURL(for: skill) == nil)
            Button {
                state.showFindings(for: skill)
            } label: {
                Text("Show findings in Health")
            }
            .axButtonToken("sukiru.library.detail.showFindings")
            Spacer(minLength: 0)
        }
    }

    private func ownershipText(_ skill: Skill) -> LocalizedStringKey {
        switch skill.ownership {
        case .vercel: "Vercel"
        case .github: "GitHub"
        case .doubleBooked: "Double-booked"
        case .ownerless: "Ownerless"
        }
    }

    @ViewBuilder
    private func scopeText(_ skill: Skill) -> some View {
        if skill.scope == .user {
            Text("User scope")
        } else if let root = state.projectRoot(of: skill) {
            Text(root)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text("Project scope")
        }
    }

    // MARK: - notices

    /// §8 degradation: a skill claimed by the Vercel ledger (solely, or
    /// double-booked) is read-only while `npx skills` is unresolvable.
    /// GitHub-owned and ownerless skills carry no such degradation
    /// (VAL-HEALTH-024).
    private func isVercelReadOnly(_ skill: Skill) -> Bool {
        guard let caps = state.capabilities, !caps.npx.resolvable else { return false }
        return skill.ownership == .vercel || skill.ownership == .doubleBooked
    }

    /// §8 / VAL-HEALTH-024: with Node.js unavailable, skills claimed by the
    /// Vercel ledger cannot be repaired or updated — say so on the skill
    /// itself, never silently.
    private func readOnlyNotice(_ skill: Skill) -> some View {
        // swiftlint:disable line_length
        let hint: LocalizedStringKey =
            "Read-only — repairing or updating this skill needs Node.js (npx skills), which is not available. Everything else still works."
        // swiftlint:enable line_length
        return HStack(spacing: 0) {
            AXToken(token: "sukiru.library.detail.readonly.\(AXTokens.skill(skill.name))")
            Label {
                Text(hint)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.callout)
            .foregroundStyle(.orange)
        }
        .accessibilityElement(children: .contain)
    }

    /// VAL-HEALTH-021 / D23: ambiguity voids attribution; the ledger claims
    /// below stay visible as data, never as authoritative ownership.
    private func ambiguousNotice(_ skill: Skill) -> some View {
        // swiftlint:disable line_length
        let explanation: LocalizedStringKey =
            "Ownership ambiguous: distinct copies of this name disagree, so attribution is voided and the skill is treated as ownerless. Ledger claims below are data, not verdicts."
        // swiftlint:enable line_length
        return HStack(spacing: 0) {
            AXToken(token: "sukiru.library.detail.ambiguous.\(AXTokens.skill(skill.name))")
            Label {
                Text(explanation)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.callout)
            .foregroundStyle(.orange)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - provenance

    private func provenanceSection(_ skill: Skill) -> some View {
        Section {
            if let vercel = skill.provenance.vercel {
                // The value parameter is a plain String (Text does not
                // localize it), so fixed phrases go through
                // String(localized:) explicitly.
                field("Installer", String(localized: "Vercel skills CLI (lock entry)"))
                if let source = vercel.source {
                    field("Source", source)
                }
                if let ref = vercel.ref {
                    field("Ref", ref)
                }
                field(
                    "Version",
                    vercel.updatedAt ?? vercel.installedAt ?? String(localized: "unknown"))
            }
            if let github = skill.provenance.github {
                field("Installer", String(localized: "GitHub gh skill (frontmatter)"))
                field("Repository", github.repo)
                if let ref = github.ref {
                    field("Ref", ref)
                }
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
        } header: {
            TokenSectionHeader(
                token: "sukiru.library.detail.provenance", title: "Provenance")
        }
    }

}

extension LibraryDetailView {
    // MARK: - placements

    private func placementsSection(_ skill: Skill) -> some View {
        Section {
            ForEach(skill.placements, id: \.path) { placement in
                LabeledContent {
                    Text(placementKindText(placement.kind))
                        .font(.callout)
                        .foregroundStyle(placement.kind == .brokenSymlink ? .orange : .secondary)
                } label: {
                    Text(placement.path)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        } header: {
            TokenSectionHeader(
                token: nil, title: "Placements", count: skill.placements.count)
        }
    }

    /// Localized badge text for a placement kind (the raw enum values are
    /// English wire tokens, never shown directly).
    private func placementKindText(_ kind: Placement.Kind) -> LocalizedStringKey {
        switch kind {
        case .directory: "directory"
        case .symlink: "symlink"
        case .brokenSymlink: "broken symlink"
        }
    }

    // MARK: - building blocks

    private func field(_ name: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(name) {
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}
