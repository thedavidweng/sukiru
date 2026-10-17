import Foundation
import SukiruCore

/// The Discover surface's lifecycle: idle until something searchable is
/// typed, searching while a query is in flight, results when a search
/// landed, failed with an explicit message (never a swallowed error).
/// Results keep their request, so an equivalent retype is recognized.
enum SearchPhase: Equatable {
    case idle
    case searching(SkillSearchRequest)
    case results([SkillSearchResult], request: SkillSearchRequest)
    case failed(String)

    var request: SkillSearchRequest? {
        switch self {
        case .searching(let request), .results(_, let request): request
        case .idle, .failed: nil
        }
    }
}

/// The owner filter, a token in the search field (like Mail's "From:")
/// rather than a second text field.
struct SearchOwnerToken: Identifiable, Hashable {
    let login: String
    var id: String { login }
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
        case .results(let results, _):
            return results
        case .idle, .searching, .failed:
            return []
        }
    }

    /// Selected results retain the visible result order, never Set iteration order.
    var selectedSearchResults: [SkillSearchResult] {
        searchResults.filter { selectedSearchResultIDs.contains($0.id) }
    }

    /// Single-result inspectors must not display an arbitrary member of a selection.
    func selectedSearchResult() -> SkillSearchResult? {
        guard selectedSearchResultIDs.count == 1 else { return nil }
        return searchResults.first { selectedSearchResultIDs.contains($0.id) }
    }

    var canInstallSelectedSearchResults: Bool {
        let results = selectedSearchResults
        return !results.isEmpty && results.count == selectedSearchResultIDs.count
            && results.allSatisfy(\.isInstallable)
    }

    /// Searches the selected backend with the typed query and owner,
    /// normalized by `SkillSearchRequest`. Runs off the main actor; the
    /// phase swap happens on completion. A stale query competing against a
    /// newer one is dropped (same generation discipline as rescan).
    /// `skippingRepeat` lets search-as-you-type leave an equivalent
    /// request's results (and selection) alone; Return always re-runs.
    func performSearch(skippingRepeat: Bool = false) {
        guard
            let request = SkillSearchRequest.parse(
                query: searchQuery, owner: searchOwner, backend: searchBackend)
        else {
            searchGeneration += 1
            selectSearchResults([])
            searchPhase = .idle
            return
        }
        if skippingRepeat, request == searchPhase.request { return }
        searchGeneration += 1
        let generation = searchGeneration
        searchPhase = .searching(request)
        selectSearchResults([])
        let environment = environment
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let results: [SkillSearchResult]
                switch request.backend {
                case .skillsDotSh:
                    results = try await SkillsDotShSearchClient(
                        transport: URLSessionMarketplaceTransport()
                    ).search(query: request.query, owner: request.owner, limit: request.limit)
                case .github:
                    // Needs gh ≥ 2.90; the view disables the backend picker
                    // when gh is unavailable.
                    results = try await GitHubSkillSearchClient(
                        runner: SystemCommandRunner(environment: environment)
                    ).search(query: request.query, owner: request.owner, limit: request.limit)
                }
                await self?.applySearchResults(results, for: request, generation: generation)
            } catch {
                await self?.applySearchFailure(
                    UserFacingError.message(for: error),
                    generation: generation)
            }
        }
    }

    private func applySearchResults(
        _ results: [SkillSearchResult], for request: SkillSearchRequest, generation: Int
    ) {
        guard generation == searchGeneration else { return }
        searchPhase = .results(results, request: request)
        selectSearchResults(Set(results.prefix(1).map(\.id)))
    }

    private func applySearchFailure(_ message: String, generation: Int) {
        guard generation == searchGeneration else { return }
        searchPhase = .failed(message)
    }

    /// The owner filter's login, nil without a token.
    var searchOwner: String? {
        searchOwnerTokens.last?.login
    }

    /// Owners to offer as a filter for the typed text, taken from the
    /// results already on screen (no extra request); none once an owner
    /// is picked.
    var searchOwnerSuggestions: [String] {
        guard searchOwnerTokens.isEmpty else { return [] }
        return SkillSearchRequest.ownerSuggestions(for: searchQuery, in: searchResults)
    }

    /// Every selection change invalidates pending preview work, including A → B → A.
    func selectSearchResults(_ ids: Set<String>) {
        selectedSearchResultIDs = ids.intersection(Set(searchResults.map(\.id)))
        searchPreviewGeneration += 1
        searchPreview = nil
        searchPreviewLoading = false
        guard let result = selectedSearchResult() else { return }
        loadPreview(for: result)
    }

    private func loadPreview(for result: SkillSearchResult) {
        let generation = searchPreviewGeneration
        searchPreviewLoading = true
        let fetcher = SkillPreviewFetcher(transport: URLSessionMarketplaceTransport())
        Task.detached(priority: .utility) { [weak self] in
            let preview = await fetcher.skill(of: result)
            await MainActor.run {
                guard let self, self.searchPreviewGeneration == generation,
                    self.selectedSearchResult()?.id == result.id
                else { return }
                self.searchPreview = preview
                self.searchPreviewLoading = false
            }
        }
    }

    // MARK: - installer choice

    /// Opens one installer sheet for the complete installable selection.
    func presentInstallSheet() {
        guard canInstallSelectedSearchResults else { return }
        resetInstallSheet(origin: .searchResult)
        showingInstallSheet = true
    }

    /// Resets the selections the install sheet shares across origins.
    func resetInstallSheet(origin: InstallOrigin) {
        installOrigin = origin
        let ghOnly =
            capabilities.map { !$0.npx.canRunSkills && $0.github.available } ?? false
        installInstaller = ghOnly ? .github : .vercel
        installTarget = .user
        ghInstallAgent = HostTable.ghInstallAgentOptions.first ?? "codex"
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
        let names = selectedSearchResults.map(\.name)
        if installOrigin == .searchResult && Set(names).count != names.count {
            installError = String(localized: "search.install.duplicateNames")
            return
        }
        do {
            let batch = try buildSelectedInstall()
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

    private func buildSelectedInstall() throws -> CommandBatch {
        let options = InstallOptions(
            vercelAgents: installInstaller == .vercel ? vercelInstallAgents.sorted() : [],
            ghAgent: installInstaller == .github ? ghInstallAgent : nil,
            ghPinRef: installInstaller == .github ? ghPinRef : nil,
            copy: installAsCopies)
        let builder = InstallPlanBuilder(report: report)
        switch installOrigin {
        case .searchResult:
            let results = selectedSearchResults
            guard !results.isEmpty, results.count == selectedSearchResultIDs.count else {
                throw InstallPlanError.noSkillsSelected
            }
            // Validate the entire selection before publishing a proposed batch.
            let batches = try results.map { result in
                try builder.build(
                    result: result, installer: installInstaller, target: installTarget,
                    options: options)
            }
            let first = batches[0]
            return CommandBatch(
                id: first.id, createdAt: first.createdAt,
                findingRefs: batches.flatMap(\.findingRefs),
                decisions: batches.flatMap(\.decisions),
                commands: batches.flatMap(\.commands),
                snapshotID: nil, status: .proposed)
        case .repository:
            guard let selection = selectedRepositorySkills() else {
                throw InstallPlanError.noSkillsSelected
            }
            return try builder.build(
                repo: selection.repo, skills: selection.skills, installer: installInstaller,
                target: installTarget, options: options)
        }
    }
}
