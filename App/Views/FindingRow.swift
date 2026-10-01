import SukiruCore
import SwiftUI

/// One finding row: a disclosure control carrying the finding token
/// (`sukiru.health.finding.<ruleID>.<skill>`), the skill and the path the
/// problem is about, its one-click fix (`….oneClickFix`), the D16 actions
/// (`….reveal` into Library, `….fix` into Pending Changes), and — when
/// expanded — the rule, a D3 severity tag, and one line per evidence entry
/// with the concrete
/// paths, lock entries, and hash values the scan emitted
/// (VAL-HEALTH-014/042).
struct FindingRow: View {
    @EnvironmentObject private var state: AppState
    let row: HealthView.FindingRowItem

    private var finding: Finding { row.entry.finding }

    private var expanded: Bool {
        state.expandedFindings.contains(row.entry.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .axButtonToken(row.token)
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.skillName ?? finding.ruleID)
                        .font(.callout.weight(.medium))
                    if let location {
                        Text(verbatim: location)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(location)
                    }
                }
                Spacer()
                if let fix = state.oneClickFix(for: finding) {
                    Button {
                        state.fix([row.entry])
                    } label: {
                        Text(fix.fixLabel)
                    }
                    .controlSize(.small)
                    .disabled(state.batchMutationInFlight)
                    .axButtonToken("\(row.token).oneClickFix")
                }
                if let orphan {
                    Button("Find Source…") {
                        state.findSource(for: orphan)
                    }
                    .controlSize(.small)
                    .disabled(state.batchMutationInFlight)
                    .axButtonToken("\(row.token).findSource")
                }
                if state.skill(matching: finding) != nil {
                    Menu {
                        Button("Reveal in Library") {
                            state.revealInLibrary(for: finding)
                        }
                        .axButtonToken("\(row.token).reveal")
                        Button("Other Repairs…") {
                            // D16 repair entry point (M4): deep-links into
                            // Pending Changes with this finding's decision
                            // panel open (VAL-CROSS-006).
                            state.beginRepair(for: finding)
                        }
                        .axButtonToken("\(row.token).fix")
                        if let orphan {
                            Divider()
                            Button("Delete Skill…", role: .destructive) {
                                state.deleteOrphan(orphan)
                            }
                            .axButtonToken("\(row.token).delete")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More actions for this finding")
                }
            }
            // §8 / VAL-CROSS-014: when EVERY actionable repair of this
            // finding needs a CLI that is missing in this environment, the
            // row says so inline — the Fix flow then shows the same hint in
            // Pending Changes instead of building a doomed batch.
            if let block = state.repairBlockHint(for: finding) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    AXToken(token: "\(row.token).repairBlocked")
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(repairBlockLabel(block))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .accessibilityElement(children: .contain)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        severityTag
                        Text(verbatim: "\(finding.ruleID) · \(finding.workspaceID)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    if finding.ruleID == "dangerous-removal-surface" {
                        Text(dangerAdvisory)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    ForEach(Array(finding.evidence.enumerated()), id: \.offset) { pair in
                        let label = EvidencePresentation.label(forKind: pair.element.kind)
                        Text("evidence.line \(label) \(pair.element.detail)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 2)
    }

    /// The skill behind an orphan finding: it gets Find Source and Delete.
    private var orphan: Skill? {
        guard ProblemKind.of(finding) == .orphan else { return nil }
        return state.skill(matching: finding)
    }

    /// The localized label for a fully-blocked repair (§8 degradation).
    private func repairBlockLabel(_ block: AppState.RepairBlock) -> LocalizedStringKey {
        switch block {
        case .needsNode: return "health.repairBlocked.needsNode"
        case .needsGitHub: return "health.repairBlocked.needsGH"
        }
    }

    /// The path the problem is about, abbreviated to `~`: the dead link, the
    /// stray copy, or the lock file.
    private var location: String? {
        let kinds = [
            "linkPath", "impostorPath", "hostPath", "placementPath", "memberPath", "lockPath"
        ]
        guard
            let path = kinds.lazy.compactMap({ kind in
                finding.evidence.first { $0.kind == kind }?.detail
            }).first
        else { return nil }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    /// VAL-HEALTH-041: the Finding model (D18) has no message field, so the
    /// dangerous-removal-surface blast radius is spelled out at the view
    /// layer — naming the at-risk skill and stating that
    /// `npx skills remove <name>` would delete it by name across ownership.
    /// The scan's own evidence lines (skillName/placementPath/ownership)
    /// render unchanged below it.
    private var dangerAdvisory: String {
        let name = finding.skillName ?? finding.ruleID
        return String(localized: "danger.removal.advisory \(name) \(name)")
    }

    private var severityTag: some View {
        Text(finding.severity.title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(severityColor.opacity(0.18), in: Capsule())
            .foregroundStyle(severityColor)
    }

    private var severityColor: Color {
        switch finding.severity {
        case .action: .red
        case .warning: .orange
        case .info: .blue
        }
    }

    private func toggle() {
        if expanded {
            state.expandedFindings.remove(row.entry.id)
        } else {
            state.expandedFindings.insert(row.entry.id)
        }
    }
}

/// One issue row (VAL-HEALTH-022): malformed data surfaces as data, never a
/// crash. The kind, the concrete path, and the parser's message render
/// directly — no disclosure needed, nothing hidden.
struct IssueRow: View {
    let issue: Issue
    let index: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            AXToken(token: "sukiru.health.issue.\(issue.kind).\(index + 1)")
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: IssuePresentation.title(forKind: issue.kind))
                    .font(.callout.weight(.medium))
                Text(verbatim: issue.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(verbatim: issue.message)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}
