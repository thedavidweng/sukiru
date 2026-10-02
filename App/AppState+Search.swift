import Foundation
import SukiruCore

/// The Search surface's lifecycle: idle until the first query,
/// searching while a query is in flight, results when a search landed,
/// failed with an explicit message (never a swallowed error).
enum SearchPhase: Equatable {
    case idle
    case searching
    case results([SkillSearchResult])
    case failed(String)
}

/// Search-surface state derivations and intents: the
/// query → backend → results flow, per-result preview, the
/// installer-choice sheet, and install-batch construction that
/// lands on the existing Pending Changes review → execute → rollback
/// pipeline (the repair safety model, unchanged).
///
/// Views stay dumb: they render `searchPhase` / `searchPreview` /
/// `pendingBatch` and dispatch these intents. All writes go through
/// SukiruCore (Sukiru keeps no ledger of its own); the only network surface in the whole
/// app is the read-only marketplace fetch.
@MainActor
extension AppState {
    /// The live search results of the current phase (empty when not loaded).
    var searchResults: [SkillSearchResult] {
        switch searchPhase {
        case .results(let results):
            return results
        case .idle, .searching, .failed:
            return []
        }
    }

    /// The selected result row, if it still exists in the live results.
    func selectedSearchResult() -> SkillSearchResult? {
        searchResults.first { $0.id == selectedSearchResultID }
    }

    /// Searches the selected backend. Runs off the main actor;
    /// the phase swap happens on completion. A stale query competing against
    /// a newer one is dropped (same generation discipline as rescan).
    func performSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let trimmedOwner = searchOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = trimmedOwner.isEmpty ? nil : trimmedOwner
        searchGeneration += 1
        let generation = searchGeneration
        searchPhase = .searching
        selectedSearchResultID = nil
        searchPreview = nil
        searchPreviewError = nil
        switch searchBackend {
        case .skillsDotSh:
            let client = SkillsDotShSearchClient(
                transport: URLSessionMarketplaceTransport())
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let results = try await client.search(query: query, owner: owner)
                    await self?.applySearchResults(results, generation: generation)
                } catch {
                    await self?.applySearchFailure(
                        UserFacingError.message(for: error),
                        generation: generation)
                }
            }
        case .github:
            // Search via the gh subprocess (needs gh ≥ 2.90; capability
            // gating happens in the view — the backend picker is disabled
            // when gh is unavailable).
            let client = GitHubSkillSearchClient(
                runner: SystemCommandRunner(environment: environment))
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let results = try await client.search(query: query, owner: owner)
                    await self?.applySearchResults(results, generation: generation)
                } catch {
                    await self?.applySearchFailure(
                        UserFacingError.message(for: error),
                        generation: generation)
                }
            }
        }
    }

    private func applySearchResults(
        _ results: [SkillSearchResult], generation: Int
    ) {
        guard generation == searchGeneration else { return }
        searchPhase = .results(results)
        selectedSearchResultID = results.first?.id
        if let first = results.first {
            loadPreview(for: first)
        }
    }

    private func applySearchFailure(_ message: String, generation: Int) {
        guard generation == searchGeneration else { return }
        searchPhase = .failed(message)
    }

    /// Loads the SKILL.md preview for the selected result,
    /// read-only, off the main actor.
    func selectSearchResult(_ id: String) {
        guard let result = searchResults.first(where: { $0.id == id }) else { return }
        selectedSearchResultID = id
        loadPreview(for: result)
    }

    private func loadPreview(for result: SkillSearchResult) {
        searchPreview = nil
        searchPreviewError = nil
        searchPreviewLoading = true
        let fetcher = SkillPreviewFetcher(transport: URLSessionMarketplaceTransport())
        Task.detached(priority: .utility) { [weak self] in
            do {
                let preview = try await fetcher.preview(of: result)
                await MainActor.run {
                    guard let self,
                        self.selectedSearchResultID == result.id
                    else { return }
                    self.searchPreview = preview
                    self.searchPreviewLoading = false
                }
            } catch {
                let message = UserFacingError.message(for: error)
                await MainActor.run {
                    guard let self,
                        self.selectedSearchResultID == result.id
                    else { return }
                    self.searchPreviewError = message
                    self.searchPreviewLoading = false
                }
            }
        }
    }

    // MARK: - installer choice

    /// The common gh --agent targets offered by the install sheet. The
    /// canonical store host heads the list; the rest are the widely adopted
    /// agent hosts the gh CLI supports (probe-verified `--agent` values).
    static let ghInstallAgentOptions = ["codex", "claude-code", "cursor", "gemini-cli"]

    /// Opens the install sheet for the selected result.
    func presentInstallSheet() {
        guard selectedSearchResult() != nil else { return }
        resetInstallSheet(origin: .searchResult)
        showingInstallSheet = true
    }

    /// Resets the selections the install sheet shares across origins.
    func resetInstallSheet(origin: InstallOrigin) {
        installOrigin = origin
        installInstaller = .vercel
        installTarget = .user
        ghInstallAgent = Self.ghInstallAgentOptions.first ?? "codex"
        ghPinRef = ""
        vercelInstallAgents = []
        let detector = HostDetector(environment: environment, fileSystem: DefaultFileSystemProbe())
        vercelInstallAgentOptions = HostTable.hosts.filter(detector.isDetected)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        installError = nil
    }

    /// Whether the selected installer is usable in this environment
    /// (capability degradation). The sheet offers the choice but renders it
    /// blocked-with-hint when the owning CLI is missing.
    func installCapabilityAvailable(_ installer: InstallerChoice) -> Bool {
        switch installer.capabilityGate {
        case .needsNode:
            return capabilities?.npx.canRunSkills ?? true
        case .needsGitHub:
            return capabilities?.github.available ?? true
        }
    }

    /// The sheet's per-installer consequence copy (consequences
    /// spelled out before any batch exists).
    func installConsequenceCopy(_ installer: InstallerChoice) -> String {
        switch installer {
        case .vercel:
            return String(
                localized: "install.consequence.vercel")
        case .github:
            return String(
                localized: "install.consequence.github")
        }
    }

    /// The Settings key for installing new Vercel skills as copies instead
    /// of links into the shared skills folder.
    static let installAsCopiesDefaultsKey = "installAsCopies"

    var installAsCopies: Bool {
        UserDefaults.standard.bool(forKey: Self.installAsCopiesDefaultsKey)
    }

    /// Builds the install batch from the sheet's current selections and
    /// opens the batch confirmation (confirm → execute → rollback).
    /// Refusals (malformed source, missing agent) surface
    /// inline; capability gating is enforced here as defense in depth
    /// (the sheet's proceed control is already disabled).
    func confirmInstall() {
        guard showingInstallSheet else { return }
        // Capability gating enforced here as defense in depth (the sheet's
        // proceed control is already disabled; a keyboard path must refuse
        // just as loudly). Refusals keep the sheet open so the hint is
        // visible.
        switch installInstaller.capabilityGate {
        case .needsNode:
            guard capabilities?.npx.canRunSkills != false else {
                installError = String(localized: "install.error.needsNode")
                return
            }
        case .needsGitHub:
            guard capabilities?.github.available != false else {
                installError = String(localized: "install.error.needsGitHub")
                return
            }
        }
        let options = InstallOptions(
            vercelAgents: installInstaller == .vercel ? vercelInstallAgents.sorted() : [],
            ghAgent: installInstaller == .github ? ghInstallAgent : nil,
            ghPinRef: installInstaller == .github ? ghPinRef : nil,
            copy: installAsCopies)
        let builder = InstallPlanBuilder()
        do {
            let batch: CommandBatch
            switch installOrigin {
            case .searchResult:
                guard let result = selectedSearchResult() else { return }
                batch = try builder.build(
                    result: result, installer: installInstaller, target: installTarget,
                    options: options)
            case .repository:
                guard let selection = selectedRepositorySkills() else {
                    throw InstallPlanError.noSkillsSelected
                }
                batch = try builder.build(
                    repo: selection.repo, skills: selection.skills, installer: installInstaller,
                    target: installTarget, options: options)
            }
            showingInstallSheet = false
            pendingBatch = batch
            repairDraft = nil
            repairError = nil
            repairBlockNotice = nil
            lastExecutionRecord = nil
            lastExecutionFailure = nil
            showingBatchConfirm = true
        } catch {
            installError = UserFacingError.message(for: error)
        }
    }
}
