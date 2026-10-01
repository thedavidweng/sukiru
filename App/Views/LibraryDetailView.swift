import SukiruCore
import SwiftUI

/// The selected skill's inspector: a single grouped form, read top to bottom
/// like a Passwords entry, with the file actions in the window toolbar.
struct LibraryDetailView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let skill = state.selectedSkill()
        Group {
            if let skill {
                SkillDetailForm(skill: skill)
                    .id(skill.selfID)
            } else {
                ContentUnavailableView {
                    Label("Select a skill to inspect it", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .toolbar(content: toolbar)
    }

    @ToolbarContentBuilder
    private func toolbar() -> some ToolbarContent {
        let skill = state.selectedSkill()
        // macOS 26+ lays toolbar items out from the column's leading edge;
        // a flexible spacer keeps the file actions beside the search field.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }
        ToolbarItemGroup {
            Button {
                state.quickLookSelectedSkill()
            } label: {
                Label("Quick Look", systemImage: "eye")
            }
            .axButtonToken(
                "sukiru.toolbar.quicklook", disabled: !state.canQuickLookSelectedSkill()
            )
            .disabled(!state.canQuickLookSelectedSkill())
            .help("Quick Look the selected skill's SKILL.md (⌘Y).")

            Button {
                if let path = skill?.placements.first?.path {
                    state.revealInFinder([path])
                }
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .disabled(skill?.placements.isEmpty ?? true)
            .help("Show the selected skill's folder in Finder")
        }
    }
}

private struct SkillDetailForm: View {
    @EnvironmentObject private var state: AppState
    let skill: Skill

    var body: some View {
        let findings = state.findingEntries(for: skill)
        Form {
            Section {
                LabeledContent("Owner") {
                    Text(skill.ownership.title)
                }
                LabeledContent("Scope") {
                    scopeText
                }
            } header: {
                header
            }
            if state.orphanFinding(for: skill) != nil {
                orphanSection
            }
            if !findings.isEmpty {
                findingsSection(findings)
            }
            LibraryHostsSection(
                skill: skill, report: state.report, environment: state.environment,
                projectRoot: state.projectRoot(of: skill))
            LibraryProvenanceSection(skill: skill)
            LibraryLocationsSection(skill: skill)
            SkillContentSection(skill: skill)
        }
        .formStyle(.grouped)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.library.detail")
                Text(skill.name)
                    .font(.title.weight(.semibold))
            }
            if let description = state.skillDescriptions[skill.selfID] {
                Text(description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .help(description)
            }
        }
        .textSelection(.enabled)
        .textCase(nil)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var scopeText: some View {
        if skill.scope == .user {
            Text("User Library")
        } else if let root = state.projectRoot(of: skill) {
            Text(root)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(root)
        } else {
            Text("Project scope")
        }
    }

    /// No installer recorded this skill, so nothing can update it: offer to
    /// hand it to `npx skills` from a known source, or to delete it.
    private var orphanSection: some View {
        Section {
            Text("problem.orphan.explanation")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Delete…", role: .destructive) {
                    state.deleteOrphan(skill)
                }
                .axButtonToken("sukiru.library.detail.orphan.delete")
                Button("Find Source…") {
                    state.findSource(for: skill)
                }
                .axButtonToken("sukiru.library.detail.orphan.findSource")
            }
            .disabled(state.batchMutationInFlight)
        } header: {
            Text("No Known Source")
        }
    }

    private func findingsSection(_ findings: [AppState.FindingEntry]) -> some View {
        Section {
            ForEach(findings, id: \.id) { entry in
                Label {
                    Text(verbatim: entry.finding.ruleID)
                } icon: {
                    SeverityIcon(severity: entry.finding.severity)
                }
            }
            HStack {
                Spacer()
                Button("Show in Health") {
                    state.showFindings(for: skill)
                }
                .axButtonToken("sukiru.library.detail.showFindings")
                .help("Review the evidence and plan a repair in Health (⌘⇧F)")
            }
        } header: {
            TokenSectionHeader(token: nil, title: "Findings", count: findings.count)
        }
    }
}

private struct SeverityIcon: View {
    let severity: Severity

    var body: some View {
        switch severity {
        case .action:
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .accessibilityLabel("action")
        case .warning:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("warning")
        case .info:
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("info")
        }
    }
}
