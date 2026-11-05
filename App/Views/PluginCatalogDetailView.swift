import SukiruCore
import SwiftUI

struct PluginCatalogDetailView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if let selected = state.selectedCatalogEntry {
                form(selected.entry, marketplace: selected.marketplace)
            } else {
                ContentUnavailableView(
                    "Select a plugin to inspect it", systemImage: "puzzlepiece.extension")
            }
        }
        .toolbar(content: toolbar)
    }

    private func form(_ entry: PluginCatalogEntry, marketplace: PluginMarketplace) -> some View {
        Form {
            Section {
                if let summary = entry.summary {
                    Text(verbatim: summary)
                }
                LabeledContent("Marketplace", value: marketplace.displayName ?? marketplace.name)
                LabeledContent("Plugin", value: entry.name)
                if let version = entry.version {
                    LabeledContent("Version", value: version)
                }
                if let source = sourceLink(entry) {
                    LabeledContent("Source") {
                        Link(source.absoluteString, destination: source)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(source.absoluteString)
                    }
                }
                if let author = entry.author {
                    LabeledContent("Author", value: author)
                }
                if let tier = entry.tier {
                    LabeledContent("Tier", value: tier.capitalized)
                }
                if let license = entry.license {
                    LabeledContent("License", value: license)
                }
                if let categories = entry.categories, !categories.isEmpty {
                    LabeledContent("Category", value: categories.joined(separator: ", "))
                }
                if let keywords = entry.keywords, !keywords.isEmpty {
                    LabeledContent("Keywords", value: keywords.joined(separator: ", "))
                }
                requirementRows(entry)
            } header: {
                HStack(spacing: 12) {
                    PluginLogo(address: entry.logo, size: 40)
                    Text(verbatim: entry.title)
                        .font(.title.weight(.semibold))
                }
                .textCase(nil)
                .foregroundStyle(.primary)
                .padding(.bottom, 8)
            }
            listingSections(entry)
            installNote(entry, marketplace: marketplace)
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func requirementRows(_ entry: PluginCatalogEntry) -> some View {
        if let platforms = entry.platforms, !platforms.isEmpty {
            LabeledContent("Platforms", value: platforms.joined(separator: ", "))
        }
        if let variables = entry.requiredEnvironment, !variables.isEmpty {
            LabeledContent("Environment", value: variables.joined(separator: ", "))
        }
    }

    /// A listing's source is where its payload lives. A path inside the marketplace
    /// checkout, a host cache folder or an install archive is not a page a user opens,
    /// and a catalog may repeat a link the Project Links section already shows.
    private func sourceLink(_ entry: PluginCatalogEntry) -> URL? {
        guard let range = entry.source.range(of: "https://"),
            let url = URL(string: String(entry.source[range.lowerBound...])),
            !["zip", "tar", "gz", "tgz"].contains(url.pathExtension),
            url.absoluteString != entry.homepage, url.absoluteString != entry.repository
        else { return nil }
        return url
    }

    @ViewBuilder
    private func installNote(
        _ entry: PluginCatalogEntry, marketplace: PluginMarketplace
    ) -> some View {
        if marketplace.host == .antigravity {
            Section {
                Text(
                    """
                    Install runs agy plugin install \(entry.name)@\(marketplace.name) \
                    and needs a signed-in agy. API keys, OAuth and other setup stay in the host.
                    """
                )
                .foregroundStyle(.secondary)
            }
        } else if marketplace.host == .codex {
            Section {
                Text(
                    """
                    Codex installs \(entry.name)@\(marketplace.name) in user scope. \
                    Local catalogs are used in place; Git marketplaces are refreshed by Codex.
                    """
                )
                .foregroundStyle(.secondary)
            }
        } else if marketplace.host == .cursor {
            Section {
                Text("Sukiru only browses Cursor's catalog; install in Customize, then Refresh.")
                    .foregroundStyle(.secondary)
            }
        } else if marketplace.host == .hermes {
            hermesNote(entry)
        } else if marketplace.host == .droid {
            Section {
                Text(
                    """
                    Install runs droid plugin install \(entry.name)@\(marketplace.name) \
                    in the scope you choose. Droid fetches Git and npm sources itself, and \
                    organization policy can limit which marketplaces and plugins it accepts.
                    """
                )
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func hermesNote(_ entry: PluginCatalogEntry) -> some View {
        Section {
            Text(
                """
                Install runs hermes plugins install \(entry.name) --no-enable. The plugin \
                starts disabled; enable it separately. Hermes installs the repository and \
                commit its catalog pins, and skips Python dependencies unless you prepare \
                them in Hermes.
                """
            )
            .foregroundStyle(.secondary)
            if entry.tier == "community" {
                Text(
                    """
                    Nous has not verified this community plugin. Read its repository \
                    before you enable it.
                    """
                )
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func listingSections(_ entry: PluginCatalogEntry) -> some View {
        let links = [
            (String(localized: "Homepage"), entry.homepage),
            (String(localized: "Repository"), entry.repository)
        ].compactMap { label, value in
            value.flatMap(URL.init(string:)).map { (label, $0) }
        }.filter { $0.1.scheme == "https" }
        if !links.isEmpty {
            Section("Project Links") {
                ForEach(links, id: \.0) { label, url in
                    Link(label, destination: url)
                        .help(url.absoluteString)
                }
            }
        }
        if let issues = entry.knownIssues, !issues.isEmpty {
            Section("Known Issues") {
                ForEach(issues, id: \.self) { Text(verbatim: $0) }
            }
        }
        if let prompts = entry.suggestedPrompts, !prompts.isEmpty {
            Section("Suggested Prompts") {
                ForEach(prompts, id: \.self) { Text(verbatim: $0) }
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }
        ColumnAction {
            Button {
                if let selected = state.selectedCatalogEntry {
                    state.manageCatalogEntry(selected.entry, marketplace: selected.marketplace)
                }
            } label: {
                if state.pluginHost == .cursor {
                    Label("Instructions for Cursor…", systemImage: "info.circle")
                } else {
                    Label("Install from Marketplace…", systemImage: "arrow.down.circle")
                }
            }
            .disabled(state.pluginActionsBusy || state.selectedCatalogEntry == nil)
            .accessibilityIdentifier("sukiru.plugins.marketplace.install")
            .help(
                state.pluginHost == .cursor
                    ? String(localized: "Choose a scope and view Cursor installation instructions")
                    : String(localized: "Preview installing this listing from its marketplace"))
        }
    }
}
