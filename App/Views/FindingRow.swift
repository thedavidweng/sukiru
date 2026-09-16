import SukiruCore
import SwiftUI

/// One finding row: a disclosure control carrying the finding token
/// (`sukiru.health.finding.<ruleID>.<skill>`), a severity tag using the D3
/// vocabulary, the D16 actions (`….reveal` into Library, `….fix` repair
/// entry point — deep-links to Library until the M4 batch flow wires up),
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
                        // D16 repair entry point. The Command Batch flow
                        // arrives in M4; in M3 the affordance deep-links to
                        // the implicated skill in Library.
                        state.revealInLibrary(for: finding)
                    } label: {
                        Text("Fix…")
                    }
                    .controlSize(.small)
                    .axButtonToken("\(row.token).fix")
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
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

    private var titleText: String {
        if let name = finding.skillName {
            return "\(finding.ruleID) — \(name)"
        }
        return finding.ruleID
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
