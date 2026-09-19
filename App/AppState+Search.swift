import Foundation
import SukiruCore

/// The Search surface's lifecycle (M5): idle until the first query,
/// searching while a query is in flight, results when a search landed,
/// failed with an explicit message (never a swallowed error).
enum SearchPhase: Equatable {
    case idle
    case searching
    case results([SkillSearchResult])
    case failed(String)
}

/// Search-surface state derivations and intents (M5, stories 22–24): the
/// query → backend → results flow, per-result preview (story 24), the
/// installer-choice sheet (story 23), and install-batch construction that
/// lands on the existing Pending Changes review → execute → rollback
/// pipeline (the seam-B safety model, unchanged).
///
/// Views stay dumb: they render `searchPhase` / `searchPreview` /
/// `pendingBatch` and dispatch these intents. All writes go through
/// SukiruCore (zero ledger red line); the only network surface in the whole
/// app is the read-only marketplace fetch (§8).
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

    /// Searches the selected backend (story 22). Runs off the main actor;
    /// the phase swap happens on completion. A stale query competing against
    /// a newer one is dropped (same generation discipline as rescan).
    func performSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
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
                    let results = try await client.search(query: query)
                    await self?.applySearchResults(results, generation: generation)
                } catch {
                    await self?.applySearchFailure(
                        (error as? MarketplaceError)?.message ?? String(describing: error),
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
                    let results = try await client.search(query: query)
                    await self?.applySearchResults(results, generation: generation)
                } catch {
                    await self?.applySearchFailure(
                        (error as? MarketplaceError)?.message ?? String(describing: error),
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

    /// Loads the SKILL.md preview for the selected result (story 24),
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
            } catch let error as MarketplaceError {
                await MainActor.run {
                    guard let self,
                        self.selectedSearchResultID == result.id
                    else { return }
                    self.searchPreviewError = error.message
                    self.searchPreviewLoading = false
                }
            } catch {
                await MainActor.run {
                    guard let self,
                        self.selectedSearchResultID == result.id
                    else { return }
                    self.searchPreviewError = String(describing: error)
                    self.searchPreviewLoading = false
                }
            }
        }
    }

    // MARK: - installer choice (story 23)

    /// The common gh --agent targets offered by the install sheet. The
    /// canonical store host heads the list; the rest are the widely adopted
    /// agent hosts the gh CLI supports (probe-verified `--agent` values).
    static let ghInstallAgentOptions = ["codex", "claude-code", "cursor", "gemini-cli"]

    /// Opens the install sheet for the selected result.
    func presentInstallSheet() {
        guard selectedSearchResult() != nil else { return }
        installInstaller = .vercel
        installTarget = .user
        ghInstallAgent = Self.ghInstallAgentOptions.first ?? "codex"
        ghPinRef = ""
        installError = nil
        showingInstallSheet = true
    }

    /// Whether the selected installer is usable in this environment
    /// (§8 degradation). The sheet offers the choice but renders it
    /// blocked-with-hint when the owning CLI is missing.
    func installCapabilityAvailable(_ installer: InstallerChoice) -> Bool {
        switch installer.capabilityGate {
        case .needsNode:
            return capabilities?.npx.resolvable ?? true
        case .needsGitHub:
            return capabilities?.github.available ?? true
        }
    }

    /// The sheet's per-installer consequence copy (story 23: consequences
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

    /// Builds the install batch from the sheet's current selections and
    /// lands it on Pending Changes for the standard review → execute →
    /// rollback flow. Refusals (malformed source, missing agent) surface
    /// inline; capability gating is enforced here as defense in depth
    /// (the sheet's proceed control is already disabled).
    func confirmInstall() {
        guard let result = selectedSearchResult(), showingInstallSheet else {
            return
        }
        // Capability gating enforced here as defense in depth (the sheet's
        // proceed control is already disabled; a keyboard path must refuse
        // just as loudly). Refusals keep the sheet open so the hint is
        // visible.
        switch installInstaller.capabilityGate {
        case .needsNode:
            guard capabilities?.npx.resolvable != false else {
                installError = String(localized: "install.error.needsNode")
                return
            }
        case .needsGitHub:
            guard capabilities?.github.available != false else {
                installError = String(localized: "install.error.needsGitHub")
                return
            }
        }
        do {
            let batch = try InstallPlanBuilder().build(
                result: result,
                installer: installInstaller,
                target: installTarget,
                ghAgent: installInstaller == .github ? ghInstallAgent : nil,
                ghPinRef: installInstaller == .github ? ghPinRef : nil)
            showingInstallSheet = false
            pendingBatch = batch
            reviewedCommands = []
            selectedCommandIndex = batch.commands.indices.first
            repairDraft = nil
            repairError = nil
            repairBlockNotice = nil
            surface = .pending
        } catch let error as InstallPlanError {
            installError = error.message
        } catch {
            installError = String(describing: error)
        }
    }
}
