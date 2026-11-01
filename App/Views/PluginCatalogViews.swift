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

    private var cursorIssues: [PluginInventoryIssue] {
        guard state.pluginHost == .cursor else { return [] }
        return (state.report?.pluginInventory?.issues ?? []).filter {
            $0.host == .cursor && $0.path.contains("/.cursor/plugins/marketplaces/")
        }
    }

    private var droidNotFetched: Bool {
        !marketplaces.isEmpty && marketplaces.allSatisfy { $0.host == .droid && $0.path == nil }
    }

    private var otherCatalogsEmpty: Bool {
        !marketplaces.isEmpty
            && marketplaces.allSatisfy {
                $0.plugins.isEmpty && $0.host != .cursor && $0.host != .claude
            }
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
                    if marketplace.host == .cursor, marketplace.plugins.isEmpty {
                        Text("The cached catalog has no listings").foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: marketplace.name)
                            if marketplace.host == .cursor {
                                Text("Cached catalog; registration scope unknown")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(verbatim: marketplace.source)
                                    .font(.caption).foregroundStyle(.secondary)
                                if let ref = marketplace.ref {
                                    Text("Git ref: \(ref)").font(.caption).foregroundStyle(
                                        .secondary)
                                }
                            }
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
                        if marketplace.host == .claude || marketplace.host == .cursor {
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
            if !cursorIssues.isEmpty {
                Section("Inspection Issues") {
                    ForEach(cursorIssues, id: \.self) { issue in
                        VStack(alignment: .leading) {
                            Text(verbatim: issue.message)
                            Text(verbatim: issue.path).foregroundStyle(.secondary)
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
            } else if marketplaces.isEmpty, state.pluginHost != .claude, cursorIssues.isEmpty {
                ContentUnavailableView {
                    Label("No cached marketplace catalog", systemImage: "shippingbox")
                } description: {
                    Text(
                        "Open \(state.pluginHost.displayName) and sign in; Sukiru reads the catalog the host caches."
                    )
                }
            } else if droidNotFetched {
                ContentUnavailableView {
                    Label("Not fetched by Droid yet", systemImage: "shippingbox")
                } description: {
                    Text("Start Droid in a project, or refresh the marketplace in Marketplaces….")
                }
            } else if otherCatalogsEmpty {
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
        if marketplace.host == .cursor { return nil }
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
