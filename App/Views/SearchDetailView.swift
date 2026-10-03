import SukiruCore
import SwiftUI

/// The selected search result in the detail column, laid out like the
/// Library inspector: name and description, where it comes from, the files
/// it ships, and its raw SKILL.md. Install sits in the window toolbar.
struct SearchDetailView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if let result = state.selectedSearchResult() {
                Form {
                    Section {
                        details(result)
                    } header: {
                        header(result)
                    }
                    if let files = state.searchPreview?.files, !files.isEmpty {
                        Section {
                            ForEach(files, id: \.self) { path in
                                Text(verbatim: path)
                                    .font(.callout.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(path)
                            }
                        } header: {
                            TokenSectionHeader(token: nil, title: "Files", count: files.count)
                        }
                    }
                    skillMDSection
                }
                .formStyle(.grouped)
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

    private func header(_ result: SkillSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.search.result.name.\(AXTokens.skill(result.name))")
                Text(result.name)
                    .font(.title.weight(.semibold))
            }
            if let description = result.description ?? state.searchPreview?.description {
                Text(description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .help(description)
            }
        }
        .textSelection(.enabled)
        .textCase(nil)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func details(_ result: SkillSearchResult) -> some View {
        if let repo = result.repo {
            LabeledContent("Source") {
                Text(repo)
                    .monospaced()
                    .textSelection(.enabled)
            }
        }
        if let installs = result.installs {
            LabeledContent("Installs") {
                Text(installs, format: .number)
            }
        }
        if let stars = result.stars {
            LabeledContent("Stars") {
                Text(stars, format: .number)
            }
        }
        LabeledContent("Found with") {
            Text(result.backend.title)
        }
        if result.isDuplicate {
            Label(
                "skills.sh lists this as a copy of a skill published elsewhere.",
                systemImage: "doc.on.doc"
            )
            .foregroundStyle(.secondary)
        }
        if let url = result.webURL {
            HStack {
                Spacer()
                Link(destination: url) {
                    Text(result.backend == .github ? "View on GitHub" : "View on skills.sh")
                }
                .help(url.absoluteString)
            }
        }
    }

    /// The raw SKILL.md, never rendered (prompt-injection risk is
    /// inspected, not trusted). An unavailable preview leaves the row
    /// installable.
    private var skillMDSection: some View {
        Section {
            if state.searchPreviewLoading {
                ProgressView("Loading SKILL.md…")
                    .controlSize(.small)
            } else if let preview = state.searchPreview {
                Text(preview.skillMD)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                Label {
                    // swiftlint:disable line_length
                    Text(
                        "Preview unavailable for this result.\nThe install re-resolves the exact skill through the official CLI."
                    )
                    // swiftlint:enable line_length
                } icon: {
                    Image(systemName: "doc.badge.xmark")
                }
                .foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.search.preview")
                Text(verbatim: "SKILL.md")
            }
        }
    }
}
