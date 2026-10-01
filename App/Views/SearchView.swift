import SukiruCore
import SwiftUI

/// The Search surface: query field, live backend picker
/// (skills.sh API / `gh skill search`), results list, and the per-result
/// detail column. Selecting a row loads the read-only SKILL.md preview;
/// "Install…" opens the installer-choice sheet whose
/// resulting Command Batch lands on the standard Pending Changes flow.
///
/// The backend picker gates on launch capabilities: skills.sh is
/// always available (a pure network read, zero CLIs), gh is
/// offered only when gh ≥ 2.90.0 is live.
struct SearchView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBar
            Divider()
            switch state.searchPhase {
            case .idle:
                idleState
            case .searching:
                searchingState
            case .failed(let message):
                failureState(message)
            case .results:
                resultsContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $state.showingInstallSheet) {
            InstallSheet()
        }
    }

    // MARK: - search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            AXToken(token: "sukiru.search.query")
            TextField("Search skills", text: $state.searchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .onSubmit {
                    state.performSearch()
                }
                .axButtonToken("sukiru.search.query")
            Button {
                state.performSearch()
            } label: {
                Text("Search")
            }
            .axButtonToken(
                "sukiru.search.run",
                disabled: state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            )
            .disabled(
                state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty)
            backendPicker
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Backend picker. gh is gated on capability: with gh
    /// unavailable the picker shows only skills.sh (GitHub-side
    /// features clearly absent, everything else works).
    @ViewBuilder
    private var backendPicker: some View {
        let ghAvailable = state.capabilities?.github.available ?? true
        HStack(spacing: 6) {
            AXToken(token: "sukiru.search.backend")
            Picker("Backend", selection: $state.searchBackend) {
                Text("skills.sh").tag(SkillSearchResult.Backend.skillsDotSh)
                Text("gh skill").tag(SkillSearchResult.Backend.github)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
            .disabled(!ghAvailable)
            if !ghAvailable {
                Text("gh unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
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

    private var resultsContent: some View {
        HStack(spacing: 0) {
            resultsList
            Divider()
            resultDetail
        }
    }

    private var resultsList: some View {
        List(selection: $state.selectedSearchResultID) {
            ForEach(state.searchResults) { result in
                SearchResultRow(result: result)
                    .tag(result.id)
            }
        }
        .listStyle(.inset)
        .frame(minWidth: 260, maxWidth: 380)
    }

    private var resultDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result = state.selectedSearchResult() {
                resultHeader(result)
                Divider()
                previewPane
                HStack(spacing: 12) {
                    Button {
                        state.presentInstallSheet()
                    } label: {
                        Text("Install…")
                    }
                    .axButtonToken(
                        "sukiru.search.install",
                        disabled: !result.isInstallable
                    )
                    .disabled(!result.isInstallable)
                    Spacer()
                }
            } else {
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                Text(result.backend.rawValue)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.gray.opacity(0.14), in: Capsule())
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
                ScrollView {
                    Text(preview)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
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
        .frame(maxHeight: .infinity, alignment: .top)
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
