import SukiruCore
import SwiftUI

/// One host's cached marketplace catalogs. Listing details come from the host's
/// cache, so a same-name installation is shown as a name match, not as provenance.
struct PluginCatalogList: View {
    @EnvironmentObject private var state: AppState
    let marketplaces: [PluginMarketplace]
    let filter: String

    var body: some View {
        List(selection: $state.selectedCatalogEntryID) {
            ForEach(marketplaces.filter { filter.isEmpty || !entries($0).isEmpty }) { marketplace in
                Section {
                    ForEach(entries(marketplace), id: \.name) { entry in
                        PluginCatalogRow(
                            entry: entry, installed: installedNames.contains(entry.name)
                        )
                        .tag(marketplace.catalogID(entry))
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: marketplace.name)
                        if let updatedAt = marketplace.updatedAt {
                            Text("Catalog cached by the host: \(updatedAt)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("sukiru.plugins.marketplace.list")
        .overlay {
            if marketplaces.isEmpty {
                ContentUnavailableView {
                    Label("No cached marketplace catalog", systemImage: "shippingbox")
                } description: {
                    Text(
                        "Open \(state.pluginHost.displayName) and sign in; Sukiru reads the catalog the host caches."
                    )
                }
            } else if marketplaces.allSatisfy({ $0.plugins.isEmpty }) {
                ContentUnavailableView(
                    "The cached catalog has no listings", systemImage: "shippingbox")
            } else if marketplaces.allSatisfy({ entries($0).isEmpty }) {
                ContentUnavailableView.search(text: filter)
            }
        }
    }

    private var installedNames: Set<String> {
        Set(state.pluginInstallations(for: state.pluginHost).map(\.identifier))
    }

    /// Category first, then name, so related listings sit together.
    private func entries(_ marketplace: PluginMarketplace) -> [PluginCatalogEntry] {
        marketplace.plugins.filter { $0.matches(filter) }.sorted {
            ($0.categories?.first ?? "~", $0.title.lowercased())
                < ($1.categories?.first ?? "~", $1.title.lowercased())
        }
    }
}

private struct PluginCatalogRow: View {
    let entry: PluginCatalogEntry
    let installed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PluginLogo(address: entry.logo, size: 28)
            details
        }
        .accessibilityIdentifier("sukiru.plugins.marketplace.row.\(entry.name)")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(verbatim: entry.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if installed {
                    Text("Same name installed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(
                            "An installed plugin has this directory name; that does not prove it came from this listing"
                        )
                }
            }
            if let summary = entry.summary {
                Text(verbatim: summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            let details = [entry.categories?.joined(separator: ", "), entry.version].compactMap {
                $0
            }
            if !details.isEmpty {
                Text(verbatim: details.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// A listing's icon, fetched only from an HTTPS address. SVG and bitmap icons both decode
/// through NSImage; anything else keeps the generic plugin symbol.
private struct PluginLogo: View {
    let address: String?
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: size * 0.55))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: address) {
            image = nil
            guard let address, let url = URL(string: address), url.scheme == "https" else {
                return
            }
            image = await Self.load(url)
        }
    }

    /// Catalog icons are a few kilobytes; a body over the limit is discarded.
    private static let byteLimit = 1 << 20

    private static func load(_ url: URL) async -> NSImage? {
        guard let (bytes, response) = try? await URLSession.shared.bytes(from: url),
            (response as? HTTPURLResponse)?.statusCode == 200,
            response.expectedContentLength <= byteLimit
        else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > byteLimit { return nil }
            }
        } catch {
            return nil
        }
        return NSImage(data: data)
    }
}

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
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
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

extension PluginMarketplace {
    func catalogID(_ entry: PluginCatalogEntry) -> String { id + "\n" + entry.name }
}

extension PluginCatalogEntry {
    var title: String { displayName ?? name }

    func matches(_ filter: String) -> Bool {
        filter.isEmpty
            || ([name, displayName, summary] + (keywords ?? []).map(Optional.some))
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(filter) }
    }
}

extension AppState {
    var selectedCatalogEntry: (entry: PluginCatalogEntry, marketplace: PluginMarketplace)? {
        guard let id = selectedCatalogEntryID else { return nil }
        for marketplace in report?.pluginInventory?.marketplaces ?? []
        where marketplace.host == pluginHost {
            if let entry = marketplace.plugins.first(where: { marketplace.catalogID($0) == id }) {
                return (entry, marketplace)
            }
        }
        return nil
    }
}
