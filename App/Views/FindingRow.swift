import SukiruCore
import SwiftUI

/// One finding row: a disclosure control carrying the finding token
/// (`sukiru.health.finding.<ruleID>.<skill>`), a severity tag using the D3
/// vocabulary, and the D16 actions (`….reveal` into Library, `….fix` into
/// Pending Changes),
/// and — when expanded — one line per evidence entry with the concrete
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
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .axButtonToken(row.token)
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleText)
                        .font(.callout.weight(.medium))
                    HStack(spacing: 6) {
                        severityTag
                        Text(finding.workspaceID)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if state.skill(matching: finding) != nil {
                    Button {
                        state.revealInLibrary(for: finding)
                    } label: {
                        Text("Reveal in Library")
                    }
                    .controlSize(.small)
                    .axButtonToken("\(row.token).reveal")
                    Button {
                        // D16 repair entry point (M4): deep-links into
                        // Pending Changes with this finding's decision panel
                        // open (VAL-CROSS-006).
                        state.beginRepair(for: finding)
                    } label: {
                        Text("Fix…")
                    }
                    .controlSize(.small)
                    .axButtonToken("\(row.token).fix")
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
                    if finding.ruleID == "dangerous-removal-surface" {
                        Text(dangerAdvisory)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    ForEach(Array(finding.evidence.enumerated()), id: \.offset) { pair in
                        Text("\(pair.element.kind): \(pair.element.detail)")
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

    /// The localized label for a fully-blocked repair (§8 degradation).
    private func repairBlockLabel(_ block: AppState.RepairBlock) -> LocalizedStringKey {
        switch block {
        case .needsNode: return "health.repairBlocked.needsNode"
        case .needsGitHub: return "health.repairBlocked.needsGH"
        }
    }

    private var titleText: String {
        if let name = finding.skillName {
            return "\(finding.ruleID) — \(name)"
        }
        return finding.ruleID
    }

    /// VAL-HEALTH-041: the Finding model (D18) has no message field, so the
    /// dangerous-removal-surface blast radius is spelled out at the view
    /// layer — naming the at-risk skill and stating that
    /// `npx skills remove <name>` would delete it by name across ownership.
    /// The scan's own evidence lines (skillName/placementPath/ownership)
    /// render unchanged below it.
    private var dangerAdvisory: String {
        let name = finding.skillName ?? finding.ruleID
        return String(
            format: String(localized: "danger.removal.advisory %@ %@"), name, name)
    }

    private var severityTag: some View {
        Text(LocalizedStringKey(finding.severity.rawValue))
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
                Text(issue.kind)
                    .font(.callout.weight(.medium))
                Text(issue.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
