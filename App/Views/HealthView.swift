import SukiruCore
import SwiftUI

/// The Health surface (§4.3): one-click health check (`sukiru.health.checkNow`,
/// non-reentrant while running), a summary line (`sukiru.health.summary`), and
/// findings grouped by rule (`sukiru.health.group.<ruleID>`) with per-finding
/// disclosure rows (`sukiru.health.finding.<ruleID>.*`) whose evidence expands
/// to concrete paths, lock entries, and hashes.
///
/// Disclosure state lives in `AppState.expandedFindings`, so it survives
/// surface switches (VAL-HEALTH-045). A health check is a rescan in M3 — the
/// findings derive from the scan report.
struct HealthView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            switch state.scanPhase {
            case .loading:
                loadingState
            case .homeMissing(let path):
                homeMissingState(path)
            case .failed(let message):
                failureState(message)
            case .loaded:
                loadedState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - states

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            HStack(spacing: 0) {
                AXToken(token: "sukiru.health.loading")
                Text("Checking library health…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func homeMissingState(_ path: String) -> some View {
        // VAL-CROSS-022: zero skill findings plus an explicit environment
        // notice — never a misleadingly healthy or silently empty report.
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.yellow)
            HStack(spacing: 0) {
                AXToken(token: "sukiru.health.environmentNotice")
                Text("Environment problem: library root not found")
                    .font(.title3.weight(.semibold))
            }
            Text(path)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 0) {
                AXToken(token: "sukiru.health.summary")
                Text("0 findings")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.red)
            HStack(spacing: 0) {
                AXToken(token: "sukiru.health.error")
                Text("Health check failed")
                    .font(.title3.weight(.semibold))
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
        }
        .padding(32)
    }

    private var loadedState: some View {
        VStack(spacing: 0) {
            header
            if let focus = state.healthFocus {
                Divider()
                focusBanner(focus)
            }
            Divider()
            findingsList
        }
    }

    // MARK: - skill focus (D16 deep-link target)

    /// Banner shown while the Health surface is focused on one skill by the
    /// Library "show findings" deep-link (D16).
    private func focusBanner(_ focus: AppState.HealthFocus) -> some View {
        HStack(spacing: 8) {
            AXToken(token: "sukiru.health.focus")
            Text("Findings for \(focus.skillName)")
                .font(.callout.weight(.medium))
            Text(focus.scopeGroup)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                state.clearHealthFocus()
            } label: {
                Text("Show All")
            }
            .axButtonToken("sukiru.health.showAll")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 12) {
            AXToken(token: "sukiru.health.title")
            Text("Health")
                .font(.headline)
            HStack(spacing: 0) {
                AXToken(token: "sukiru.health.summary")
                Text(summaryText)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                state.rescan()
            } label: {
                Text("Check Now")
            }
            .axButtonToken(
                "sukiru.health.checkNow", disabled: state.healthCheckRunning
            )
            .disabled(state.healthCheckRunning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var summaryText: String {
        let count = state.report?.findings.count ?? 0
        if count == 0 {
            return String(localized: "No findings — library looks healthy")
        }
        return String(localized: "\(count) findings")
    }

    // MARK: - findings

    @ViewBuilder
    private var findingsList: some View {
        let findings = state.focusedFindings(state.report?.findings ?? [])
        if findings.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
                if state.healthFocus != nil {
                    Text("No findings implicate this skill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No findings — library looks healthy")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(groups(findings), id: \.ruleID) { group in
                    Section {
                        ForEach(group.findings, id: \.id) { entry in
                            FindingRow(entry: entry)
                        }
                    } header: {
                        HStack(spacing: 0) {
                            AXToken(token: "sukiru.health.group.\(group.ruleID)")
                            Text("\(group.ruleID) (\(group.findings.count))")
                        }
                        .accessibilityElement(children: .contain)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    struct FindingEntry: Identifiable {
        let id: String
        let finding: Finding
    }

    struct FindingGroup {
        let ruleID: String
        let findings: [FindingEntry]
    }

    /// Groups findings by rule, preserving the report's deterministic order.
    private func groups(_ findings: [Finding]) -> [FindingGroup] {
        var order: [String] = []
        var byRule: [String: [FindingEntry]] = [:]
        for (index, finding) in findings.enumerated() {
            let id = AppState.findingID(finding, index: index)
            if byRule[finding.ruleID] == nil {
                order.append(finding.ruleID)
            }
            byRule[finding.ruleID, default: []].append(
                FindingEntry(id: id, finding: finding))
        }
        return order.map { FindingGroup(ruleID: $0, findings: byRule[$0] ?? []) }
    }
}

/// One finding row: a disclosure control carrying the finding token
/// (`sukiru.health.finding.<ruleID>.<skill-or-index>`), a severity tag using
/// the D3 vocabulary, and — when expanded — one line per evidence entry.
struct FindingRow: View {
    @EnvironmentObject private var state: AppState
    let entry: HealthView.FindingEntry

    private var token: String {
        let finding = entry.finding
        let subject = finding.skillName.map(AXTokens.skill) ?? "general"
        return "sukiru.health.finding.\(finding.ruleID).\(subject)"
    }

    private var expanded: Bool {
        state.expandedFindings.contains(entry.id)
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
                .axButtonToken(token)
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleText)
                        .font(.callout.weight(.medium))
                    HStack(spacing: 6) {
                        severityTag
                        Text(entry.finding.workspaceID)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(entry.finding.evidence.enumerated()), id: \.offset) { pair in
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
        if let name = entry.finding.skillName {
            return "\(entry.finding.ruleID) — \(name)"
        }
        return entry.finding.ruleID
    }

    private var severityTag: some View {
        Text(LocalizedStringKey(entry.finding.severity.rawValue))
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(severityColor.opacity(0.18), in: Capsule())
            .foregroundStyle(severityColor)
    }

    private var severityColor: Color {
        switch entry.finding.severity {
        case .action: .red
        case .warning: .orange
        case .info: .blue
        }
    }

    private func toggle() {
        if expanded {
            state.expandedFindings.remove(entry.id)
        } else {
            state.expandedFindings.insert(entry.id)
        }
    }
}
