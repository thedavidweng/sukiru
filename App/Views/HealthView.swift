import SukiruCore
import SwiftUI

/// The Health surface: one-click health check (`sukiru.health.checkNow`,
/// non-reentrant while running — `sukiru.health.loading` + `.disabled` suffix),
/// a summary line (`sukiru.health.summary`) counting
/// problems and how many Fix All (`sukiru.health.fixAll`) repairs in one
/// confirmed batch, a per-workspace filter
/// (`sukiru.health.filter.workspace`) with an explicit
/// empty-filter state, findings grouped by plain-language
/// problem (`sukiru.health.group.<problem>`, `ProblemKind`; notes collapsed)
/// with per-finding disclosure
/// rows (`sukiru.health.finding.<ruleID>.*`) whose evidence expands to the
/// concrete paths, lock entries, and hashes the scan emitted,
/// and a separate issues section for malformed data
/// (`sukiru.health.issue.<kind>.*`).
///
/// Disclosure and selection state live in `AppState`, so they survive surface
/// switches. A health check is a rescan — the findings
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
        // Zero skill findings plus an explicit environment
        // notice — never a misleadingly healthy or silently empty report.
        ContentUnavailableView {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.health.environmentNotice")
                Label(
                    "Environment problem: library root not found",
                    systemImage: "exclamationmark.triangle"
                )
            }
        } description: {
            VStack(spacing: 8) {
                Text(path)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                HStack(spacing: 0) {
                    AXToken(token: "sukiru.health.summary")
                    Text("0 findings")
                }
            }
        }
    }

    private func failureState(_ message: String) -> some View {
        ContentUnavailableView {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.health.error")
                Label("Health check failed", systemImage: "exclamationmark.triangle")
            }
        } description: {
            Text(message)
        }
    }

    private var loadedState: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // A focused skill lives in one scope, so the workspace filter
            // would only repeat the banner's count.
            if let focus = state.healthFocus {
                HealthFocusBanner(focus: focus)
            } else {
                HealthFilterBar()
            }
            Divider()
            findingsList
        }
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 12) {
            AXToken(token: "sukiru.health.title")
            HStack(spacing: 0) {
                AXToken(token: "sukiru.health.summary")
                Text(summaryText)
                    .foregroundStyle(.secondary)
            }
            if state.healthCheckRunning {
                // The run state stays visible while a check
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
            let fixable = state.fixableEntries(problemEntries)
            Button {
                state.fix(fixable)
            } label: {
                Text("Fix All (\(fixable.count))")
            }
            .buttonStyle(.borderedProminent)
            .axButtonToken(
                "sukiru.health.fixAll", disabled: fixable.isEmpty || state.batchMutationInFlight
            )
            .disabled(fixable.isEmpty || state.batchMutationInFlight)
            .help("Repair every problem that needs no choice, in one confirmed batch")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Findings that are problems (notes excluded), after focus and filter.
    private var problemEntries: [AppState.FindingEntry] {
        state.visibleHealthEntries().filter { ProblemKind.of($0.finding).isProblem }
    }

    /// Counts problems, not notes; the full row count (notes included)
    /// still equals the rendered rows.
    private var summaryText: String {
        let problems = problemEntries.count
        let fixable = state.fixableEntries(problemEntries).count
        if problems == 0 {
            return String(localized: "No problems")
        }
        return String(localized: "\(problems) problems, \(fixable) fixable in one click")
    }

    // MARK: - findings

    @ViewBuilder
    private var findingsList: some View {
        let entries = state.visibleHealthEntries()
        let issues = state.visibleIssues()
        if entries.isEmpty && issues.isEmpty {
            // ContentUnavailableView only takes its intrinsic height; without
            // this the VStack is centered and the header sinks.
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $state.selectedFindingID) {
                ForEach(state.problemGroups()) { group in
                    ProblemSection(group: group, rows: rows(group.entries))
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

    /// Explicit empty states, distinguished by cause: skill focus,
    /// workspace filter landing on a zero-finding workspace,
    /// or a genuinely healthy library.
    @ViewBuilder
    private var emptyState: some View {
        if state.healthFocus != nil {
            ContentUnavailableView {
                Label("No findings implicate this skill", systemImage: "checkmark.seal")
            }
        } else if state.healthWorkspaceFilter != nil {
            ContentUnavailableView {
                HStack(spacing: 0) {
                    AXToken(token: "sukiru.health.emptyFilter")
                    Label("No findings in this workspace", systemImage: "checkmark.seal")
                }
            }
        } else {
            ContentUnavailableView {
                HStack(spacing: 0) {
                    AXToken(token: "sukiru.health.healthy")
                    Label("No findings — library looks healthy", systemImage: "checkmark.seal")
                }
            }
        }
    }

    /// One finding row plus its (collision-disambiguated) AX token.
    struct FindingRowItem: Identifiable {
        let entry: AppState.FindingEntry
        let token: String

        var id: String { entry.id }
    }

    /// Row items in report order. Tokens are
    /// `sukiru.health.finding.<ruleID>.<skill>`; the rare same-rule
    /// same-skill repeat (a name flagged in two scopes) gets a `-2`/`-3`
    /// suffix so every row keeps a unique label.
    private func rows(_ entries: [AppState.FindingEntry]) -> [FindingRowItem] {
        var tokenCounts: [String: Int] = [:]
        return entries.map { entry in
            let finding = entry.finding
            let subject = finding.skillName.map(AXTokens.skill) ?? "general"
            let base = "sukiru.health.finding.\(finding.ruleID).\(subject)"
            let seen = tokenCounts[base, default: 0]
            tokenCounts[base] = seen + 1
            return FindingRowItem(entry: entry, token: seen == 0 ? base : "\(base)-\(seen + 1)")
        }
    }
}

/// One problem kind: a plain-language explanation, a Fix button for every
/// one-click repair in the section, and its rows. Notes start collapsed,
/// except while focused on one skill, where every finding is what was asked
/// for.
private struct ProblemSection: View {
    @EnvironmentObject private var state: AppState
    let group: AppState.ProblemGroup
    let rows: [HealthView.FindingRowItem]
    @State private var expanded: Bool?

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { expanded ?? (group.kind.isProblem || state.healthFocus != nil) },
            set: { expanded = $0 })
    }

    var body: some View {
        Section(isExpanded: isExpanded) {
            // A row, not part of the header: macOS clips section headers to
            // one line, which truncated the explanation with no way to read it.
            Text(group.kind.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .selectionDisabled()
            ForEach(rows) { row in
                FindingRow(row: row)
                    .tag(row.entry.id)
            }
        } header: {
            header
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AXToken(token: "sukiru.health.group.\(group.kind.rawValue)")
            Label(group.kind.title, systemImage: group.kind.symbol)
                .font(.headline)
            Text("\(group.entries.count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            let fixable = state.fixableEntries(group.entries)
            if fixable.count > 1 {
                Button {
                    state.fix(fixable)
                } label: {
                    Text("Fix \(fixable.count)")
                }
                .controlSize(.small)
                .disabled(state.batchMutationInFlight)
                .axButtonToken("sukiru.health.group.\(group.kind.rawValue).fix")
            }
        }
        .textCase(nil)
        .accessibilityElement(children: .contain)
        .padding(.vertical, 4)
    }
}
