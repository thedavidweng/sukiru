import SukiruCore
import SwiftUI

/// The Search surface: the toolbar search field, the backend picker
/// (skills.sh API / `gh skill search`), and the results list. The selected
/// result's preview lives in the detail column (`SearchDetailView`).
///
/// The backend picker gates on launch capabilities: skills.sh is
/// always available (a pure network read, zero CLIs), gh is
/// offered only when gh ≥ 2.90.0 is live.
struct SearchView: View {
    @EnvironmentObject private var state: AppState

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
                case .results(let results):
                    if results.isEmpty {
                        ContentUnavailableView.search(text: state.searchQuery)
                    }
                }
            }
            .searchable(
                text: $state.searchQuery, placement: .toolbar, prompt: Text("Search skills")
            )
            .onSubmit(of: .search) {
                state.performSearch()
            }
            .toolbar {
                ToolbarItem {
                    ownerField
                }
                ToolbarItem {
                    backendPicker
                }
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

    /// Backend picker. gh is gated on capability: with gh
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
            .disabled(!ghAvailable)
        }
        .accessibilityElement(children: .contain)
        .help(ghAvailable ? Text("Backend") : Text("gh unavailable"))
    }

    /// Limits the search to one GitHub owner (`--owner` for gh, the
    /// `owner` parameter for skills.sh).
    private var ownerField: some View {
        TextField("search.ownerField", text: $state.searchOwner)
            .textFieldStyle(.roundedBorder)
            .frame(width: 120)
            .onSubmit(state.performSearch)
            .help("Only show skills from this GitHub user or organization")
    }

    // MARK: - states

    private var idleState: some View {
        SurfacePlaceholder(
            token: "sukiru.search.idle",
            icon: "magnifyingglass",
            title: "Search skills by name",
            // swiftlint:disable line_length
            explanation:
                "Search the skills.sh marketplace or GitHub, preview any SKILL.md before installing, then send the install through Pending Changes."
                // swiftlint:enable line_length
        )
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

/// The selected search result in the detail column: header and the
/// read-only SKILL.md preview, with Install in the window toolbar.
struct SearchDetailView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if let result = state.selectedSearchResult() {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        resultHeader(result)
                        Divider()
                        previewPane
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView {
                    Label("Select a result to preview it", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .toolbar(content: toolbar)
    }

    @ToolbarContentBuilder
    private func toolbar() -> some ToolbarContent {
        let installable = state.selectedSearchResult()?.isInstallable ?? false
        // macOS 26+ lays toolbar items out from the column's leading edge;
        // a flexible spacer keeps Install at the trailing edge.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }
        ToolbarItem {
            Button {
                state.presentInstallSheet()
            } label: {
                Label("Install…", systemImage: "arrow.down.circle")
            }
            .axButtonToken("sukiru.search.install", disabled: !installable)
            .disabled(!installable)
            .help("Install the selected skill (⌘⇧I)")
        }
    }

    // MARK: - result header + preview

    private func resultHeader(_ result: SkillSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AXToken(token: "sukiru.search.result.name.\(AXTokens.skill(result.name))")
                Text(result.name)
                    .font(.title3.weight(.semibold))
                if let popularity = result.popularityLabel {
                    Text(popularity)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(result.backend.title)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
            }
            if let repo = result.repo {
                Text(repo)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let description = result.description, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            }
        }
    }

    /// The read-only SKILL.md preview: raw text, never rendered
    /// (prompt-injection risk is inspected, not trusted). Loads on
    /// selection; unavailable previews render an explicit note, the row
    /// stays installable.
    @ViewBuilder
    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.search.preview")
                Text("SKILL.md preview")
                    .font(.headline)
            }
            .accessibilityElement(children: .contain)
            if state.searchPreviewLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading preview…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let error = state.searchPreviewError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if let preview = state.searchPreview {
                Text(preview)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // swiftlint:disable line_length
                Text(
                    "Preview unavailable for this result.\nThe install re-resolves the exact skill through the official CLI."
                )
                // swiftlint:enable line_length
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// One search result row: token carrier + name + repo + popularity + badge.
struct SearchResultRow: View {
    let result: SkillSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                AXToken(token: "sukiru.search.row.\(AXTokens.skill(result.name))")
                Text(result.name)
                    .font(.body.weight(.medium))
            }
            .accessibilityElement(children: .contain)
            if let repo = result.repo {
                Text(repo)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let popularity = result.popularityLabel {
                Text(popularity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
    /// The picker label, reused as the result's source badge.
    var title: LocalizedStringKey {
        switch self {
        case .skillsDotSh: "skills.sh"
        case .github: "gh skill"
        }
    }
}
