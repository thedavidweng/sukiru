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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Bumped when a rescan leaves the whole library clean; drives the
    /// healthy seal's bounce.
    @State private var healthyBounce = 0

    /// Row and count changes from a rescan animate unless Reduce Motion is on.
    private var changeAnimation: Animation? {
        reduceMotion ? nil : .default
    }

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
        findingsList
            .surfaceBar {
                header
                Divider()
                // A focused skill lives in one scope, so the workspace filter
                // would only repeat the banner's count.
                if let focus = state.healthFocus {
                    HealthFocusBanner(focus: focus)
                } else {
                    HealthFilterBar()
                }
            }
            .onChange(of: isHealthy) { wasHealthy, nowHealthy in
                if nowHealthy && !wasHealthy && !reduceMotion {
                    healthyBounce += 1
                }
            }
    }

    /// The unfiltered, unfocused library has nothing left to show.
    private var isHealthy: Bool {
        state.healthFocus == nil && state.healthWorkspaceFilter == nil
            && state.visibleHealthEntries().isEmpty && state.visibleIssues().isEmpty
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 12) {
            AXToken(token: "sukiru.health.title")
            HStack(spacing: 0) {
                AXToken(token: "sukiru.health.summary")
                Text(summaryText)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
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
            if state.queuedChangeCount == 0 {
                fixAllButton(fixable)
                    .buttonStyle(.borderedProminent)
            } else {
                fixAllButton(fixable)
                Button {
                    state.checkout()
                } label: {
                    Text("Review \(state.queuedChangeCount) Changes")
                        .contentTransition(.numericText())
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.batchMutationInFlight)
                .axButtonToken("sukiru.health.review", disabled: state.batchMutationInFlight)
                .help("Apply every queued change in one batch, with one snapshot")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(changeAnimation, value: summaryText)
    }

    private func fixAllButton(_ fixable: [AppState.FindingEntry]) -> some View {
        Button {
            state.fixAll(fixable)
        } label: {
            Text("Fix All (\(fixable.count))")
                .contentTransition(.numericText())
        }
        .axButtonToken(
            "sukiru.health.fixAll", disabled: fixable.isEmpty || state.batchMutationInFlight
        )
        .disabled(fixable.isEmpty || state.batchMutationInFlight)
        .help("Repair every problem that needs no choice, together with queued repairs")
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

    private var findingsList: some View {
        let entries = state.visibleHealthEntries()
        let issues = state.visibleIssues()
        return List(selection: $state.selectedFindingID) {
            ForEach(state.problemGroups()) { group in
                ProblemSection(group: group, rows: rows(group.entries))
            }
            if !issues.isEmpty {
                Section {
                    ForEach(Array(issues.enumerated()), id: \.element) { pair in
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
        .overlay {
            if entries.isEmpty && issues.isEmpty {
                emptyState
            }
        }
        .animation(changeAnimation, value: entries.map(\.id) + issues.map(\.path))
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
                    Label("The library looks healthy", systemImage: "checkmark.seal")
                        .symbolEffect(.bounce, value: healthyBounce)
                }
            }
        }
    }

    /// One finding row plus its (collision-disambiguated) AX token.
    struct FindingRowItem: Identifiable {
        let entry: AppState.FindingEntry
        let token: String

        /// The token, not `entry.id`: entry ids embed the report index, which
        /// shifts on every rescan, so surviving rows would be redrawn as new
        /// ones instead of staying put while fixed rows animate away.
        var id: String { token }
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

/// One problem kind: an info button for its plain-language explanation, a
/// Fix button for every one-click repair in the section, and its rows. Notes
/// start collapsed, except while focused on one skill, where every finding is
/// what was asked for.
private struct ProblemSection: View {
    @EnvironmentObject private var state: AppState
    let group: AppState.ProblemGroup
    let rows: [HealthView.FindingRowItem]
    @State private var expanded: Bool?
    @State private var showingExplanation = false

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { expanded ?? (group.kind.isProblem || state.healthFocus != nil) },
            set: { expanded = $0 })
    }

    var body: some View {
        Section(isExpanded: isExpanded) {
            if showingExplanation {
                // Untagged, so the list never selects it.
                Text(group.kind.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
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
            infoButton
            Spacer()
            let fixable = state.fixableEntries(group.entries)
                .filter { state.cartItem(for: $0.finding) == nil }
            if fixable.count > 1 {
                Button {
                    state.queueFixes(fixable)
                } label: {
                    Text("Queue \(fixable.count) Fixes")
                }
                .controlSize(.small)
                .disabled(state.batchMutationInFlight)
                .axButtonToken("sukiru.health.group.\(group.kind.rawValue).fix")
                .help("Add these repairs to Pending Changes")
            }
            if group.kind == .orphan {
                findSourcesButton
            }
        }
        .textCase(nil)
        .accessibilityElement(children: .contain)
        .padding(.vertical, 4)
    }

    /// Shows the problem's explanation as the section's first row. A popover
    /// would inherit the section header's one-line, bold styling.
    private var infoButton: some View {
        Button {
            showingExplanation.toggle()
            if showingExplanation {
                expanded = true
            }
        } label: {
            Image(systemName: showingExplanation ? "info.circle.fill" : "info.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("About This Problem")
        .accessibilityLabel("About This Problem")
    }

    /// Looks up every orphan on skills.sh and queues the verified matches.
    @ViewBuilder private var findSourcesButton: some View {
        if state.sourceMatchingInFlight {
            ProgressView()
                .controlSize(.small)
        } else {
            Button("Find Sources") {
                state.matchSources(group.entries)
            }
            .controlSize(.small)
            .disabled(state.batchMutationInFlight || !state.canAdoptFromSource)
            .axButtonToken(
                "sukiru.health.group.orphan.findSources", disabled: !state.canAdoptFromSource
            )
            .help(
                state.canAdoptFromSource
                    ? "Match each skill to a skills.sh listing and queue adoption of confirmed matches"
                    : "orphan.findSource.needsNode")
        }
    }
}
