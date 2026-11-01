import SukiruCore
import SwiftUI

struct PluginCatalogDetailView: View {
    @EnvironmentObject private var state: AppState

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
                LabeledContent("Marketplace", value: marketplace.name)
                LabeledContent("Plugin", value: entry.name)
                LabeledContent("Version", value: entry.version ?? String(localized: "Unknown"))
                LabeledContent("Source", value: entry.source)
                if let author = entry.author {
                    LabeledContent("Author", value: author)
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
    private func listingSections(_ entry: PluginCatalogEntry) -> some View {
        let links = [
            (String(localized: "Homepage"), entry.homepage),
            (String(localized: "Repository"), entry.repository)
        ].compactMap { label, value in
            value.flatMap(URL.init(string:)).map { (label, $0) }
        }.filter { $0.1.scheme == "https" }
        if !links.isEmpty {
            Section("Project Links") {
                ForEach(links, id: \.1) { label, url in
                    Link(label, destination: url)
                        .help(url.absoluteString)
                }
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
        ToolbarItem {
            Button {
                if let selected = state.selectedCatalogEntry {
                    state.manageCatalogEntry(selected.entry, marketplace: selected.marketplace)
                }
            } label: {
                Label("Install from Marketplace…", systemImage: "arrow.down.circle")
            }
            .disabled(state.pluginActionsBusy || state.selectedCatalogEntry == nil)
            .accessibilityIdentifier("sukiru.plugins.marketplace.install")
            .help("Preview installing this listing from its marketplace")
        }
    }
}
