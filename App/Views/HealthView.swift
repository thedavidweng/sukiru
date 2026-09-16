import SukiruCore
import SwiftUI

/// The Health surface (§4.3): one-click health check (`sukiru.health.checkNow`,
/// non-reentrant while running — `sukiru.health.loading` + `.disabled` suffix,
/// VAL-HEALTH-046), a summary line (`sukiru.health.summary`) whose count always
/// equals the rendered finding rows (VAL-HEALTH-034), a per-workspace filter
/// (`sukiru.health.filter.workspace`, VAL-HEALTH-015) with an explicit
/// empty-filter state (VAL-HEALTH-047), findings grouped by rule
/// (`sukiru.health.group.<ruleID>`, VAL-HEALTH-012) with per-finding disclosure
/// rows (`sukiru.health.finding.<ruleID>.*`) whose evidence expands to the
/// concrete paths, lock entries, and hashes the scan emitted
/// (VAL-HEALTH-014/042), and a separate issues section for malformed data
/// (`sukiru.health.issue.<kind>.*`, VAL-HEALTH-022).
///
/// Disclosure and selection state live in `AppState`, so they survive surface
/// switches (VAL-HEALTH-045). A health check is a rescan in M3 — the findings
/// derive from the scan report.
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
                HealthFocusBanner(focus: focus)
            }
            Divider()
            HealthFilterBar()
            Divider()
            findingsList
        }
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
            if state.healthCheckRunning {
                // VAL-HEALTH-046: the run state stays visible while a check
                // is in flight, even when a previous report is on screen.
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    AXToken(token: "sukiru.health.loading")
                }
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

    /// The summary count is the number of finding rows actually rendered —
    /// after the skill focus and the workspace filter — so it always equals
    /// the row count (VAL-HEALTH-034) and shows 0 on an empty filter
    /// (VAL-HEALTH-047).
    private var summaryText: String {
        let count = state.visibleHealthEntries().count
        if count == 0 {
            return String(localized: "0 findings")
        }
        return String(localized: "\(count) findings")
    }

    // MARK: - findings

    @ViewBuilder
    private var findingsList: some View {
        let entries = state.visibleHealthEntries()
        let issues = state.visibleIssues()
        if entries.isEmpty && issues.isEmpty {
            emptyState
        } else {
            List(selection: $state.selectedFindingID) {
                ForEach(groups(entries)) { group in
                    Section {
                        ForEach(group.rows) { row in
                            FindingRow(row: row)
                                .tag(row.entry.id)
                        }
                    } header: {
                        HStack(spacing: 0) {
                            AXToken(token: "sukiru.health.group.\(group.ruleID)")
                            Text("\(group.ruleID) (\(group.rows.count))")
                        }
                        .accessibilityElement(children: .contain)
                    }
                }
                if !issues.isEmpty {
                    Section {
                        ForEach(Array(issues.enumerated()), id: \.offset) { pair in
                            IssueRow(issue: pair.element, index: pair.offset)
                        }
                    } header: {
                        HStack(spacing: 0) {
                            AXToken(token: "sukiru.health.group.issues")
                            Text("Issues (\(issues.count))")
                        }
                        .accessibilityElement(children: .contain)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    /// Explicit empty states, distinguished by cause: skill focus (D16),
    /// workspace filter landing on a zero-finding workspace (VAL-HEALTH-047),
    /// or a genuinely healthy library (VAL-HEALTH-033).
    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            if state.healthFocus != nil {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
                Text("No findings implicate this skill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else if state.healthWorkspaceFilter != nil {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
                HStack(spacing: 0) {
                    AXToken(token: "sukiru.health.emptyFilter")
                    Text("No findings in this workspace")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
                HStack(spacing: 0) {
                    AXToken(token: "sukiru.health.healthy")
                    Text("No findings — library looks healthy")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One finding row plus its (collision-disambiguated) AX token.
    struct FindingRowItem: Identifiable {
        let entry: AppState.FindingEntry
        let token: String

        var id: String { entry.id }
    }

    struct FindingGroup: Identifiable {
        let ruleID: String
        let rows: [FindingRowItem]

        var id: String { ruleID }
    }

    /// Groups findings by rule, preserving the report's deterministic order
    /// (VAL-HEALTH-012). Tokens are `sukiru.health.finding.<ruleID>.<skill>`;
    /// the rare same-rule same-skill repeat (a name flagged in two scopes)
    /// gets a `-2`/`-3` suffix so every row keeps a unique label.
    private func groups(_ entries: [AppState.FindingEntry]) -> [FindingGroup] {
        var order: [String] = []
        var byRule: [String: [FindingRowItem]] = [:]
        var tokenCounts: [String: Int] = [:]
        for entry in entries {
            let finding = entry.finding
            let subject = finding.skillName.map(AXTokens.skill) ?? "general"
            let base = "sukiru.health.finding.\(finding.ruleID).\(subject)"
            let seen = tokenCounts[base, default: 0]
            tokenCounts[base] = seen + 1
            let token = seen == 0 ? base : "\(base)-\(seen + 1)"
            if byRule[finding.ruleID] == nil {
                order.append(finding.ruleID)
            }
            byRule[finding.ruleID, default: []].append(
                FindingRowItem(entry: entry, token: token))
        }
        return order.map { FindingGroup(ruleID: $0, rows: byRule[$0] ?? []) }
    }
}
