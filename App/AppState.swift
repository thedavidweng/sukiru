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
    /// Sidebar surfaces (§4.3). `library` is the first-launch surface (D15 —
    /// no onboarding).
    enum Surface: String, CaseIterable, Identifiable, Hashable {
        case library
        case health
        case pending
        case snapshots
        case search
        case settings

        var id: String { rawValue }
    }

    /// Scan lifecycle. `homeMissing` is the D4 fatal condition
    /// (`SUKIRU_HOME` set but nonexistent): the app renders an explicit error
    /// state instead of a misleadingly empty library (VAL-CROSS-022).
    enum ScanPhase: Equatable {
        case loading
        case loaded
        case homeMissing(String)
        case failed(String)
    }

    @Published var surface: Surface = .library
    @Published private(set) var scanPhase: ScanPhase = .loading
    @Published private(set) var report: ScanReport?
    /// nil while the (async, background) capability probes are in flight.
    @Published private(set) var capabilities: CapabilityReport?
    /// Runtime project-roots list (D20). Seeded from `SUKIRU_ROOTS`; add and
    /// remove in Settings, then Refresh (or the automatic rescan below)
    /// updates every surface.
    @Published private(set) var projectRoots: [String]
    /// Selected skill in Library (identity via `Self.skillID`), surviving
    /// surface switches.
    @Published var selectedSkillID: String?
    /// Expanded finding rows in Health, surviving surface switches.
    @Published var expandedFindings: Set<String> = []
    /// True while a Health "check now" run is in flight (non-reentrant).
    @Published private(set) var healthCheckRunning = false

    /// The launch environment (SUKIRU_HOME / SUKIRU_ROOTS / XDG overrides),
    /// identical wiring to the CLI (architecture §4.2). Read-only display
    /// only; runtime root edits go through `projectRoots`.
    let environment: SukiruEnvironment
    private let capabilityCache: CapabilityCache

    init() {
        let environment = SukiruEnvironment(reader: ProcessEnvironmentReader())
        self.environment = environment
        self.projectRoots = environment.projectRoots
        self.capabilityCache = CapabilityCache(
            detector: CapabilityDetector(environment: environment))
    }

    /// Stable identity for a skill row: scope + name + first placement path
    /// (a name can legitimately appear once per scope and per project root).
    nonisolated static func skillID(_ skill: Skill) -> String {
        let anchor = skill.placements.first?.path ?? "-"
        return "\(skill.scope.rawValue)|\(skill.name)|\(anchor)"
    }

    /// Stable identity for a finding row within one report.
    nonisolated static func findingID(_ finding: Finding, index: Int) -> String {
        "\(finding.ruleID)|\(finding.workspaceID)|\(finding.skillName ?? "-")|\(index)"
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
    }

    /// Re-runs the scan against the current environment and project roots.
    /// The previous report stays on screen while the scan runs (no flicker);
    /// surfaces swap when the new report lands. Used by the initial load,
    /// explicit Refresh (Settings control and ⌘R), root add/remove, and the
    /// Health check-now control — a health check IS a scan in M3.
    func rescan() {
        let environment = Self.makeEnvironment(roots: projectRoots)
        let engine = ScanEngine(environment: environment)
        let request = ScanRequest()
        healthCheckRunning = true
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let report = try engine.scan(request)
                await MainActor.run {
                    guard let self else { return }
                    self.report = report
                    self.scanPhase = .loaded
                    self.healthCheckRunning = false
                    self.pruneSelection(using: report)
                }
            } catch let problem as FatalEnvironmentProblem {
                await MainActor.run {
                    guard let self else { return }
                    switch problem {
                    case .sukiruHomeMissing(let path):
                        self.report = nil
                        self.scanPhase = .homeMissing(path)
                    }
                    self.healthCheckRunning = false
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.scanPhase = .failed(String(describing: error))
                    self.healthCheckRunning = false
                }
            }
        }
    }

    /// Runs the capability probes off the main actor via the shared cache
    /// (§8: never block launch). Repeat calls reuse the cache.
    func detectCapabilities() {
        let cache = capabilityCache
        Task.detached(priority: .utility) { [weak self] in
            let report = cache.current()
            await MainActor.run { self?.capabilities = report }
        }
    }

    /// Adds a project root (D20) and rescans so every surface updates.
    func addProjectRoot(_ path: String) {
        guard !path.isEmpty, !projectRoots.contains(path) else { return }
        projectRoots.append(path)
        projectRoots.sort()
        rescan()
    }

    /// Presents a folder picker and adds the chosen project root (D20).
    func addProjectRootViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addProjectRoot(url.path)
    }

    /// Removes a project root (D20) and rescans.
    func removeProjectRoot(_ path: String) {
        projectRoots.removeAll { $0 == path }
        rescan()
    }

    /// The currently selected skill, if it still exists in the report.
    func selectedSkill() -> Skill? {
        guard let report, let selectedSkillID else { return nil }
        return report.skills.first { Self.skillID($0) == selectedSkillID }
    }

    /// Drops selection/disclosure state that no longer resolves after a
    /// rescan (e.g. the skill's directory was deleted — VAL-CROSS-021).
    private func pruneSelection(using report: ScanReport) {
        let selectionAlive =
            selectedSkillID.map { id in
                report.skills.contains { Self.skillID($0) == id }
            } ?? true
        if !selectionAlive {
            self.selectedSkillID = nil
        }
        let live = Set(
            report.findings.indices.map { Self.findingID(report.findings[$0], index: $0) })
        expandedFindings = expandedFindings.intersection(live)
    }

    /// Builds a scan environment identical to the CLI wiring (§4.2) except
    /// that the runtime project-roots list replaces `SUKIRU_ROOTS` (D20).
    /// Explicit roots are encoded back into `SUKIRU_ROOTS` so the engine's
    /// D5 precedence (explicit `--root` never merges) is untouched — the app
    /// always scans with default precedence over ITS root list.
    private static func makeEnvironment(roots: [String]) -> SukiruEnvironment {
        var vars = ProcessInfo.processInfo.environment
        if roots.isEmpty {
            vars.removeValue(forKey: SukiruEnvironment.sukiruRootsKey)
        } else {
            vars[SukiruEnvironment.sukiruRootsKey] = roots.joined(separator: ":")
        }
        return SukiruEnvironment(reader: DictionaryEnvironmentReader(vars))
    }
}
