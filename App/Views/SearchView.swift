import SukiruCore
import SwiftUI

/// The Discover surface: the toolbar search field, which names the source
/// it searches, the source picker under it (skills.sh API /
/// `gh skill search`), and the results list. The selected result's
/// preview lives in the detail column (`SearchDetailView`).
///
/// One field does all the searching. An owner filter is a token in that
/// field, picked from suggestions as the owner's name is typed, the way
/// Mail turns a name into a "From:" token.
///
/// The source picker gates on launch capabilities: skills.sh is
/// always available (a pure network read, zero CLIs), gh is
/// offered only when gh ≥ 2.90.0 is live.
struct SearchView: View {
    @EnvironmentObject private var state: AppState
    @State private var pendingSearch: Task<Void, Never>?

    var body: some View {
        // The list stays even when empty, so the column starts with a scroll
        // view and the toolbar matches every other surface.
        resultsList
            .overlay {
                switch state.searchPhase {
                case .idle:
                    idleState
                case .searching:
                    searchingState
                case .failed(let message):
                    failureState(message)
                case .results(let results, let request):
                    if results.isEmpty {
                        noResultsState(request)
                    }
                }
            }
            .searchable(
                text: $state.searchQuery, tokens: $state.searchOwnerTokens, placement: .toolbar,
                prompt: searchPrompt
            ) { token in
                Text(verbatim: token.login)
            }
            .searchSuggestions {
                ForEach(state.searchOwnerSuggestions, id: \.self) { owner in
                    Label("search.ownerSuggestion \(owner)", systemImage: "person.crop.circle")
                        .searchCompletion(SearchOwnerToken(login: owner))
                }
            }
            .onSubmit(of: .search, searchNow)
            .onChange(of: state.searchQuery) { scheduleSearch() }
            .onChange(of: state.searchBackend) { scheduleSearch() }
            .onChange(of: state.searchOwnerTokens) { old, new in
                pickedOwner(added: new.count > old.count)
            }
            // Where to search sits under the toolbar, like Finder's search
            // scope bar, so the toolbar keeps room for the column's actions.
            .surfaceBar {
                HStack {
                    backendPicker
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        state.presentRepositoryInstallSheet()
                    } label: {
                        Label("Install from Repository…", systemImage: "plus")
                    }
                    .axButtonToken("sukiru.search.installFromRepository")
                    .help("Install skills from a GitHub repository")
                }
            }
            .sheet(isPresented: $state.showingInstallSheet) {
                InstallSheet()
            }
    }

    /// The field says which source it searches, so it never reads as the
    /// Library's filter.
    private var searchPrompt: Text {
        state.searchBackend == .github ? Text("Search GitHub") : Text("Search skills.sh")
    }

    /// Source picker. gh is gated on capability: with gh
    /// unavailable the picker shows only skills.sh (GitHub-side
    /// features clearly absent, everything else works).
    private var backendPicker: some View {
        let ghAvailable = state.capabilities?.github.available ?? true
        return HStack(spacing: 0) {
            AXToken(token: "sukiru.search.backend")
            Picker("Backend", selection: $state.searchBackend) {
                ForEach(SkillSearchResult.Backend.allCases, id: \.self) { backend in
                    Text(backend.title).tag(backend)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(!ghAvailable)
        }
        .accessibilityElement(children: .contain)
        .help(ghAvailable ? Text("Backend") : Text("gh unavailable"))
    }

    /// Searches once typing pauses, waiting less as the query grows, as
    /// `npx skills find` does, so each keystroke is not a network request
    /// (or a `gh` subprocess).
    private func scheduleSearch() {
        pendingSearch?.cancel()
        let delay = max(150, 350 - state.searchQuery.count * 50)
        pendingSearch = Task {
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            state.performSearch(skippingRepeat: true)
        }
    }

    private func searchNow() {
        pendingSearch?.cancel()
        state.performSearch()
    }

    /// The typed text was the owner's name, so picking the owner consumes
    /// it. Both backends filter by one owner, so a newly picked owner
    /// replaces the previous one.
    private func pickedOwner(added: Bool) {
        if added {
            state.searchQuery = ""
        }
        if state.searchOwnerTokens.count > 1 {
            state.searchOwnerTokens = Array(state.searchOwnerTokens.suffix(1))
        }
        scheduleSearch()
    }

    // MARK: - states

    @ViewBuilder
    private var idleState: some View {
        if state.searchBackend == .github, state.searchOwner != nil {
            SurfacePlaceholder(
                token: "sukiru.search.idle",
                icon: "magnifyingglass",
                title: "Type a skill name to search",
                explanation:
                    "gh skill can't list an owner's skills. Type a skill name after the owner."
            )
        } else {
            SurfacePlaceholder(
                token: "sukiru.search.idle",
                icon: "magnifyingglass",
                title: "Search skills by name",
                // swiftlint:disable line_length
                explanation:
                    "To see one owner's skills, type their GitHub name and pick it from the suggestions. Preview any SKILL.md, then install through Pending Changes."
                    // swiftlint:enable line_length
            )
        }
    }

    @ViewBuilder
    private func noResultsState(_ request: SkillSearchRequest) -> some View {
        if request.listsOwner, let owner = request.owner {
            ContentUnavailableView {
                HStack(spacing: 0) {
                    AXToken(token: "sukiru.search.noOwnerResults")
                    Label("search.noOwnerResults \(owner)", systemImage: "magnifyingglass")
                }
            }
        } else {
            ContentUnavailableView.search(text: request.query)
        }
    }

    private var searchingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            HStack(spacing: 0) {
                AXToken(token: "sukiru.search.searching")
                Text("Searching…")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureState(_ message: String) -> some View {
        ContentUnavailableView {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.search.error")
                Label("Search failed", systemImage: "exclamationmark.triangle")
            }
        } description: {
            Text(message)
        }
    }

    private var resultsList: some View {
        List(selection: selection) {
            ForEach(state.searchResults) { result in
                SearchResultRow(result: result)
                    .tag(result.id)
            }
        }
        .listStyle(.inset)
    }

    /// Selecting a row also loads its SKILL.md preview.
    private var selection: Binding<String?> {
        Binding(
            get: { state.selectedSearchResultID },
            set: { id in
                if let id {
                    state.selectSearchResult(id)
                } else {
                    state.selectedSearchResultID = nil
                }
            })
    }
}

/// One search result row: token carrier + name + repo + popularity + badge.
struct SearchResultRow: View {
    let result: SkillSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.search.row.\(AXTokens.skill(result.name))")
                Text(result.name)
                    .fontWeight(.medium)
                    .foregroundStyle(result.isDuplicate ? .secondary : .primary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .contain)
            HStack(spacing: 4) {
                if let repo = result.repo {
                    Text(repo)
                        .monospaced()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let popularity = result.popularityLabel {
                    if result.repo != nil {
                        Text(verbatim: "·")
                    }
                    Text(popularity)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let description = result.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

extension SkillSearchResult.Backend {
    /// The picker label, reused as the result's "Found with" value.
    var title: LocalizedStringKey {
        switch self {
        case .skillsDotSh: "skills.sh"
        case .github: "gh skill"
        }
    }
}
