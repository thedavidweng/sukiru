import SukiruCore
import SwiftUI

/// One host's cached marketplace catalogs. Listing details come from the host's
/// cache, so a same-name installation is shown as a name match, not as provenance.
struct PluginCatalogList: View {
    @EnvironmentObject private var state: AppState
    let marketplaces: [PluginMarketplace]
    let filter: String

    private var claudeIssues: [PluginInventoryIssue] {
        (state.report?.pluginInventory?.issues ?? []).filter { $0.host == .claude }
    }

    var body: some View {
        List(selection: $state.selectedCatalogEntryID) {
            ForEach(marketplaces.filter { filter.isEmpty || !entries($0).isEmpty }) { marketplace in
                Section {
                    ForEach(entries(marketplace), id: \.name) { entry in
                        PluginCatalogRow(
                            entry: entry, installation: installation(entry, in: marketplace)
                        )
                        .tag(marketplace.catalogID(entry))
                    }
                    if marketplace.host == .claude, marketplace.plugins.isEmpty, filter.isEmpty {
                        Text("No locally cached plugins").foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: marketplace.name)
                            if marketplace.host == .droid || marketplace.host == .claude {
                                Group {
                                    Text(
                                        verbatim: marketplace.source
                                            + (marketplace.ref.map { " · " + $0 } ?? ""))
                                    if marketplace.path == nil { Text("Not fetched by Droid yet") }
                                    if marketplace.scope == "org" {
                                        Text("Organization settings")
                                    } else if marketplace.scope == "user" {
                                        Text("User Library")
                                    } else if marketplace.scope == "local" {
                                        Text("Local project settings: \(marketplace.scopeRoot)")
                                    } else if marketplace.scope == "project" {
                                        Text(
                                            verbatim: URL(fileURLWithPath: marketplace.scopeRoot)
                                                .lastPathComponent
                                        )
                                        .help(marketplace.scopeRoot)
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            if let updatedAt = marketplace.updatedAt {
                                Text("Catalog cached by the host: \(updatedAt)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if marketplace.host == .claude {
                            Menu {
                                let actions = ["marketplace-refresh", "marketplace-remove"]
                                ForEach(actions, id: \.self) { action in
                                    Button(PluginActionTitle.title(action)) {
                                        state.manageMarketplace(marketplace, action: action)
                                    }
                                    .accessibilityIdentifier(
                                        "sukiru.plugins.marketplace.\(action).\(marketplace.id)"
                                    )
                                    .help("Preview an operation for this marketplace")
                                }
                            } label: {
                                Label("Marketplace Actions", systemImage: "ellipsis.circle")
                            }
                            .accessibilityIdentifier(
                                "sukiru.plugins.marketplace.actions.\(marketplace.id)"
                            )
                            .help("Preview an operation for this marketplace")
                        }
                    }
                }
            }
            if state.pluginHost == .claude {
                if !claudeIssues.isEmpty {
                    Section {
                        DisclosureGroup("Inspection Issues") {
                            ForEach(claudeIssues, id: \.self) { issue in
                                Text(verbatim: issue.message + ": " + issue.path)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("sukiru.plugins.marketplace.list")
        .overlay {
            if marketplaces.isEmpty, state.pluginHost == .droid {
                ContentUnavailableView {
                    Label("No marketplaces", systemImage: "shippingbox")
                } description: {
                    Text("Add a marketplace to Droid; Sukiru lists the catalogs Droid has fetched.")
                } actions: {
                    Button("Add Factory Plugins…") {
                        state.newPluginOperation(
                            host: .droid, action: "marketplace-add",
                            target: "Factory-AI/factory-plugins")
                    }
                    .accessibilityIdentifier("sukiru.plugins.marketplace.add.official")
                    .help("Preview registering Factory's official marketplace")
                }
            } else if marketplaces.isEmpty, state.pluginHost == .claude, claudeIssues.isEmpty {
                ContentUnavailableView {
                    Label("No configured marketplaces", systemImage: "shippingbox")
                } actions: {
                    Button("Add Marketplace…") {
                        state.newPluginOperation(host: .claude, action: "marketplace-add")
                    }
                    .accessibilityIdentifier("sukiru.plugins.marketplace.add.empty")
                    .help("Preview registering a marketplace with this host")
                }
            } else if marketplaces.isEmpty, state.pluginHost != .claude {
                ContentUnavailableView {
                    Label("No cached marketplace catalog", systemImage: "shippingbox")
                } description: {
                    Text(
                        "Open \(state.pluginHost.displayName) and sign in; Sukiru reads the catalog the host caches."
                    )
                }
            } else if marketplaces.allSatisfy({ $0.host == .droid && $0.path == nil }) {
                ContentUnavailableView {
                    Label("Not fetched by Droid yet", systemImage: "shippingbox")
                } description: {
                    Text("Start Droid in a project, or refresh the marketplace in Marketplaces….")
                }
            } else if state.pluginHost != .claude, marketplaces.allSatisfy({ $0.plugins.isEmpty }) {
                ContentUnavailableView(
                    "The cached catalog has no listings", systemImage: "shippingbox")
            } else if !filter.isEmpty && marketplaces.allSatisfy({ entries($0).isEmpty }) {
                ContentUnavailableView.search(text: filter)
            }
        }
        .onChange(
            of: marketplaces.flatMap { marketplace in
                entries(marketplace).map { marketplace.catalogID($0) }
            }
        ) { _, visible in
            if let selected = state.selectedCatalogEntryID, !visible.contains(selected) {
                state.selectedCatalogEntryID = nil
            }
        }
    }

    /// Droid identifies an installation by plugin and marketplace, so its match is exact;
    /// elsewhere only the name can match.
    private func installation(
        _ entry: PluginCatalogEntry, in marketplace: PluginMarketplace
    ) -> PluginCatalogRow.Installation? {
        let installations = state.pluginInstallations(for: state.pluginHost)
        if marketplace.host == .claude {
            let recorded = installations.filter {
                $0.identifier == "\(entry.name)@\(marketplace.name)"
            }
            return recorded.isEmpty ? nil : .recorded(recorded)
        }
        if marketplace.host == .droid {
            return installations.contains { $0.identifier == "\(entry.name)@\(marketplace.name)" }
                ? .installed : nil
        }
        return installations.contains { $0.identifier == entry.name } ? .sameName : nil
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
    enum Installation {
        case installed, sameName
        case recorded([PluginInstallation])
    }

    let entry: PluginCatalogEntry
    let installation: Installation?

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
                if case .installed = installation {
                    Text("Installed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if case .sameName = installation {
                    Text("Same name installed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(
                            "An installed plugin has this directory name; that does not prove it came from this listing"
                        )
                }
            }
            if case .recorded(let records) = installation {
                ForEach(records) { record in
                    HStack(spacing: 4) {
                        Text("Recorded by host")
                        if record.scope == "user" {
                            Text("User Library")
                        } else if record.scope == "local" {
                            Text("Local project settings: \(record.scopeRoot)")
                        } else {
                            Text(verbatim: "\(record.scope): \(record.scopeRoot)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
