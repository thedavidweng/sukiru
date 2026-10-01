import AppKit
import Foundation
import SukiruCore

/// The app's single observable state object (architecture §4.3: views are
/// dumb — they render SukiruCore value types and dispatch user intents here).
///
/// Everything the surfaces show derives from two sources: the latest
/// `ScanReport` (seam A) and the latest `CapabilityReport` (launch-time
/// probes, §8). Both load asynchronously so the first frame never blocks on
/// subprocesses or disk walks. Selection and disclosure state live here so
/// they survive surface switches (VAL-HEALTH-045).
@MainActor
final class AppState: ObservableObject {
    /// Scan lifecycle. `homeMissing` is the D4 fatal condition (`SUKIRU_HOME`
    /// set but nonexistent): an explicit error state instead of a misleading
    /// empty library (VAL-CROSS-022).
    enum ScanPhase: Equatable {
        case loading
        case loaded
        case homeMissing(String)
        case failed(String)
    }

    /// A Health-surface focus set by the Library deep-link (D16): show only
    /// the findings that implicate this skill in this scope.
    struct HealthFocus: Equatable {
        let skillName: String
        /// The ownership-bucket workspace id (`user` / `project:<root>`);
        /// findings carry this id or a host workspace nested under it.
        let scopeGroup: String
    }

    @Published var surface: Surface = .library
    @Published var libraryScope: LibraryScope = .all
    @Published private(set) var scanPhase: ScanPhase = .loading
    @Published private(set) var report: ScanReport?
    @Published var skillDescriptions: [String: String] = [:]
    /// nil while the (async, background) capability probes are in flight.
    @Published private(set) var capabilities: CapabilityReport?
    /// Runtime project-roots list (D20). `SUKIRU_ROOTS` wins when set (the
    /// CLI-identical fixture path); otherwise the list the user built in
    /// Settings is restored from user defaults.
    @Published private(set) var projectRoots: [String]
    /// True while a user-requested capability re-probe runs.
    @Published var capabilityCheckRunning = false
    /// The installer CLI currently being installed or updated via Homebrew.
    @Published var installerInFlight: InstallerTool?
    /// The tail of a failed Homebrew run, per tool, shown under its row.
    @Published var installerFailures: [InstallerTool: String] = [:]
    /// Selected skill in Library (identity via `Self.skillID`), survives surface switches.
    @Published var selectedSkillID: String?
    /// Expanded finding rows in Health, surviving surface switches.
    @Published var expandedFindings: Set<String> = []
    /// Active Health skill focus (D16 deep-link), nil = unfiltered.
    @Published var healthFocus: HealthFocus?
    /// Active Health workspace filter (VAL-HEALTH-015): a workspace id from
    /// the report (`user`, `host:<id>`…), nil = all.
    @Published var healthWorkspaceFilter: String?
    /// Selected finding row in Health (stable id via `Self.findingID`); the
    /// keyboard reveal/evidence menus act on it (VAL-CROSS-004).
    @Published var selectedFindingID: String?
    /// True while a Health "check now" run is in flight (non-reentrant,
    /// VAL-HEALTH-046). Held for a minimum duration so the running state is
    /// observable on sub-100ms fixture scans.
    @Published private(set) var healthCheckRunning = false

    // MARK: - Repair / Command Batch state (M4, seam B)

    /// The finding a repair is being chosen for (Health "Fix…" deep-link,
    /// D16/VAL-CROSS-006); non-nil while the decision panel is up.
    @Published var repairDraft: RepairDraft?
    /// The proposed batch under review in Pending Changes; nil whenever no
    /// batch is on the table (before a decision, after execute/discard).
    @Published var pendingBatch: CommandBatch?
    /// Indices of `pendingBatch.commands` the user has acknowledged
    /// (VAL-REPAIR-007: Execute stays gated until each command is reviewed).
    @Published var reviewedCommands: Set<Int> = []
    /// Selected command row in Pending Changes (drives the detail pane and
    /// the keyboard review menu command).
    @Published var selectedCommandIndex: Int?
    /// Batch-construction refusal text (stale finding, ownership rule) —
    /// rendered inline, never swallowed. (Core diagnostic text, English by
    /// design, like CLI stderr.)
    @Published var repairError: String?
    /// A capability-blocked repair attempt (§8, VAL-REPAIR-049): rendered
    /// as a localized inline hint, separate from `repairError` so the copy
    /// flows through the string catalog.
    @Published var repairBlockNotice: RepairBlock?
    /// True while a batch execution OR a rollback is in flight. Gates
    /// Execute and every rollback affordance (VAL-REPAIR-055: no rollback
    /// mid-execution; executions are globally serialized).
    @Published var batchMutationInFlight = false
    /// The most recent in-app execution (succeeded or failed) — the result
    /// banner on Pending Changes.
    @Published var lastExecutionRecord: ExecutionRecord?
    /// A pre-command execution refusal (lock busy, snapshot failure).
    @Published var lastExecutionFailure: String?
    /// Snapshots history rows (batch executions + rollback events) from the
    /// on-disk records — persisted across relaunches (VAL-CROSS-012).
    @Published var historyRows: [HistoryRow] = []
    /// Selected history row in Snapshots (drives the diff pane + rollback cmd).
    @Published var selectedHistoryID: String?
    /// Rollback refusal/error text, surfaced on the Snapshots surface.
    @Published var rollbackError: String?
    /// Whether the double-booked arbitration sheet (D10) is presented.
    @Published var showingArbitrationSheet = false
    /// Whether the ownerless adopt sheet (D11) is presented.
    @Published var showingAdoptSheet = false
    /// Adopt-sheet inputs: both user-supplied, never prefilled
    /// (VAL-REPAIR-051).
    @Published var adoptRepo = ""
    @Published var adoptPath = ""

    // MARK: - Search / Install state (M5, stories 22–24)

    /// The query being run and the active backend (story 22): the skills.sh
    /// API (network read) or `gh skill search` (needs gh ≥ 2.90).
    @Published var searchQuery = ""
    @Published var searchBackend: SkillSearchResult.Backend = .skillsDotSh
    /// Search lifecycle, selected row, and its SKILL.md preview (story 24)
    /// with fetch flags/errors.
    @Published var searchPhase: SearchPhase = .idle
    @Published var selectedSearchResultID: String?
    @Published var searchPreview: String?
    @Published var searchPreviewError: String?
    @Published var searchPreviewLoading = false
    /// Install sheet presentation, installer choice (story 23; Vercel
    /// default — broader coverage) and target scope.
    @Published var showingInstallSheet = false
    @Published var installInstaller: InstallerChoice = .vercel
    @Published var installTarget: InstallTarget = .user
    /// gh-ledger install host (--agent; sheet offers the common host set)
    /// and optional --pin ref.
    @Published var ghInstallAgent = "codex"
    @Published var ghPinRef = ""
    /// Install-batch build refusal (stale source, malformed repo).
    @Published var installError: String?

    /// The launch environment (SUKIRU_HOME / SUKIRU_ROOTS / XDG overrides),
    /// identical wiring to the CLI (§4.2). Read-only; root edits via
    /// `projectRoots`.
    let environment: SukiruEnvironment
    private let capabilityCache: CapabilityCache
    static let projectRootsDefaultsKey = "projectRoots"

    init() {
        Self.includeHomebrewInPath()
        let environment = SukiruEnvironment(reader: ProcessEnvironmentReader())
        self.environment = environment
        self.projectRoots =
            environment.projectRoots.isEmpty
            ? UserDefaults.standard.stringArray(forKey: Self.projectRootsDefaultsKey) ?? []
            : environment.projectRoots
        self.capabilityCache = CapabilityCache(
            detector: CapabilityDetector(environment: environment))
    }

    /// Kicks off the launch sequence: fatal-environment pre-check (D4, cheap
    /// synchronous `exists`), then the initial scan and the capability probes
    /// — both asynchronous, so the first frame renders immediately
    /// (VAL-HEALTH-002).
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        rescan()
        detectCapabilities()
        // Batch history is on-disk state, not a cache: it must be present at
        // launch and survive relaunches (VAL-CROSS-012).
        loadHistory()
    }

    /// Re-runs the scan against the current environment and project roots.
    /// The previous report stays on screen while the scan runs (no flicker);
    /// surfaces swap when the new report lands. Used by the initial load,
    /// explicit Refresh (Settings control and ⌘R), root add/remove, and the
    /// Health check-now control — a health check IS a scan in M3.
    ///
    /// A generation counter keeps overlapping runs coherent (only the latest
    /// run's completion applies), and the running flag is held for a minimum
    /// visible duration (0.6 s) so VAL-HEALTH-046's non-reentrant run state
    /// is observable even on millisecond-fast fixture scans.
    func rescan() {
        let environment = Self.makeEnvironment(roots: projectRoots)
        let engine = ScanEngine(environment: environment)
        let request = ScanRequest()
        scanGeneration += 1
        let generation = scanGeneration
        let startedAt = ContinuousClock.now
        healthCheckRunning = true
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let report = try engine.scan(request)
                await self?.applyScanResult(
                    .success(report), generation: generation, startedAt: startedAt)
            } catch {
                await self?.applyScanResult(
                    .failure(error), generation: generation, startedAt: startedAt)
            }
        }
    }

    /// Monotonic counter identifying the latest requested scan; stale
    /// completions are dropped instead of clobbering newer state.
    var scanGeneration = 0

    /// Monotonic counter identifying the latest requested search; stale
    /// completions are dropped instead of clobbering newer state.
    var searchGeneration = 0
    /// Minimum time the running state stays visible once a scan starts.
    private static let minimumRunVisibility: Duration = .milliseconds(600)

    /// Applies a finished scan on the main actor; stale generations (a
    /// newer rescan was requested meanwhile) are ignored entirely.
    private func applyScanResult(
        _ result: Result<ScanReport, any Error>,
        generation: Int,
        startedAt: ContinuousClock.Instant
    ) async {
        guard generation == scanGeneration else { return }
        switch result {
        case .success(let report):
            self.report = report
            self.scanPhase = .loaded
            self.pruneSelection(using: report)
            loadSkillDescriptions(for: report, generation: generation)
        case .failure(let error):
            if let problem = error as? FatalEnvironmentProblem {
                switch problem {
                case .sukiruHomeMissing(let path):
                    self.report = nil
                    self.scanPhase = .homeMissing(path)
                }
            } else {
                self.scanPhase = .failed(String(describing: error))
            }
        }
        let elapsed = startedAt.duration(to: .now)
        if elapsed < Self.minimumRunVisibility {
            try? await Task.sleep(for: Self.minimumRunVisibility - elapsed)
        }
        guard generation == scanGeneration else { return }
        healthCheckRunning = false
    }

    /// Runs the capability probes off the main actor via the shared cache
    /// (§8: never block launch); repeat calls reuse it.
    func detectCapabilities() {
        let cache = capabilityCache
        Task.detached(priority: .utility) { [weak self] in
            let report = cache.current()
            await MainActor.run { self?.capabilities = report }
        }
    }

    /// Re-probes both CLIs, bypassing the launch-time cache.
    func recheckCapabilities() {
        guard !capabilityCheckRunning else { return }
        capabilityCheckRunning = true
        let cache = capabilityCache
        Task.detached(priority: .userInitiated) { [weak self] in
            let report = cache.refresh()
            await MainActor.run {
                self?.capabilities = report
                self?.capabilityCheckRunning = false
            }
        }
    }

    /// Adds a project root (D20) and rescans so every surface updates.
    func addProjectRoot(_ path: String) {
        guard !path.isEmpty, !projectRoots.contains(path) else { return }
        projectRoots.append(path)
        projectRoots.sort()
        saveProjectRoots()
        rescan()
    }

    /// An explicit `SUKIRU_ROOTS` session is a fixture or CLI-parity run, so
    /// its edits never overwrite the user's saved folders.
    private func saveProjectRoots() {
        guard environment.projectRoots.isEmpty else { return }
        UserDefaults.standard.set(projectRoots, forKey: Self.projectRootsDefaultsKey)
    }

    /// Removes a project root (D20) and rescans.
    func removeProjectRoot(_ path: String) {
        projectRoots.removeAll { $0 == path }
        if libraryScope == .project(path) {
            libraryScope = .all
            selectedSkillID = nil
        }
        saveProjectRoots()
        rescan()
    }

    /// The currently selected skill, if it still exists in the report.
    func selectedSkill() -> Skill? {
        guard let report, let selectedSkillID else { return nil }
        return report.skills.first { Self.skillID($0) == selectedSkillID }
    }

    /// The previewable `SKILL.md` for a skill: the first placement (the
    /// report's canonical-first ordering) whose SKILL.md is actually on
    /// disk. Broken-symlink placements whose file vanished are skipped —
    /// Quick Look of a missing file would show an empty panel.
    func skillMarkdownURL(for skill: Skill) -> URL? {
        for placement in skill.placements {
            let url = URL(fileURLWithPath: placement.path)
                .appendingPathComponent("SKILL.md", isDirectory: false)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// Opens Quick Look on the selected skill's SKILL.md, in place
    /// (VAL-HEALTH-023/030). Called from the detail-pane button
    /// (`sukiru.library.quicklook`) and the View-menu shortcut (⌘Y).
    func quickLookSelectedSkill() {
        guard let skill = selectedSkill(), let url = skillMarkdownURL(for: skill) else {
            return
        }
        QuickLookPreviewer.shared.preview(fileAt: url)
    }

    /// Whether the Quick Look affordances should be enabled right now (a
    /// selected skill with a previewable SKILL.md on disk).
    func canQuickLookSelectedSkill() -> Bool {
        selectedSkill().flatMap { skillMarkdownURL(for: $0) } != nil
    }

    // The Health-surface derivations (skill focus, workspace filter, issue
    // attribution, finding → Library reveal) live in `AppState+Health.swift`.

    /// Drops selection/disclosure/focus state that no longer resolves after
    /// a rescan (e.g. the skill's directory was deleted — VAL-CROSS-021).
    private func pruneSelection(using report: ScanReport) {
        let selectionAlive =
            selectedSkillID.map { id in
                report.skills.contains { Self.skillID($0) == id }
            } ?? true
        if !selectionAlive {
            self.selectedSkillID = nil
        }
        if let focus = healthFocus {
            let focusAlive = report.skills.contains { skill in
                skill.name == focus.skillName && scopeGroup(for: skill) == focus.scopeGroup
            }
            if !focusAlive {
                healthFocus = nil
            }
        }
        let live = Set(
            report.findings.indices.map { Self.findingID(report.findings[$0], index: $0) })
        expandedFindings = expandedFindings.intersection(live)
        if let selectedFindingID, !live.contains(selectedFindingID) {
            self.selectedFindingID = nil
        }
        if let filter = healthWorkspaceFilter {
            let workspaceAlive = report.workspaces.contains { $0.id == filter }
            if !workspaceAlive {
                healthWorkspaceFilter = nil
            }
        }
        // A repair draft mints its finding ID from the report it was opened
        // against; after a rescan (external Refresh or post-mutation) the ID
        // space changes, so a stale draft is dropped instead of risking a
        // stale-reference batch (VAL-REPAIR-056).
        let draftIsStale = repairDraft.map { draft in
            !FindingID.assignments(for: report.findings).contains { $0.id == draft.findingID }
        }
        if draftIsStale == true {
            repairDraft = nil
            showingArbitrationSheet = false
            showingAdoptSheet = false
        }
    }

    /// Builds a scan environment identical to the CLI wiring (§4.2) except
    /// that the runtime project-roots list replaces `SUKIRU_ROOTS` (D20).
    /// Explicit roots are encoded back into `SUKIRU_ROOTS` so the engine's
    /// D5 precedence (explicit `--root` never merges) is untouched — the app
    /// always scans with default precedence over ITS root list. Also used by
    /// the seam-B executors (CLIExecutor, Rollback) so app-initiated
    /// mutations run against exactly the scanned environment.
    static func makeEnvironment(roots: [String]) -> SukiruEnvironment {
        var vars = ProcessInfo.processInfo.environment
        if roots.isEmpty {
            vars.removeValue(forKey: SukiruEnvironment.sukiruRootsKey)
        } else {
            vars[SukiruEnvironment.sukiruRootsKey] = roots.joined(separator: ":")
        }
        return SukiruEnvironment(reader: DictionaryEnvironmentReader(vars))
    }
}
