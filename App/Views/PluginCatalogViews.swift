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
                            entry: entry, installation: installation(entry, in: marketplace)
                        )
                        .tag(marketplace.catalogID(entry))
                    }
                    if marketplace.host == .cursor, marketplace.plugins.isEmpty {
                        Text("The cached catalog has no listings").foregroundStyle(.secondary)
                    }
                    if marketplace.host == .codex, marketplace.plugins.isEmpty, filter.isEmpty {
                        if inspectionIssues.contains(where: {
                            $0.path.hasPrefix((marketplace.path ?? "") + "/")
                        }) {
                            Text("Catalog could not be read").foregroundStyle(.secondary)
                        } else {
                            if codexCatalogExists(marketplace) {
                                Text("No locally cached plugins").foregroundStyle(.secondary)
                            } else {
                                Text("Catalog not found").foregroundStyle(.secondary)
                            }
                        }
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
                            if marketplace.host == .droid || marketplace.host == .codex {
                                Group {
                                    Text(
                                        verbatim: marketplace.source
                                            + (marketplace.ref.map { " · " + $0 } ?? ""))
                                    if marketplace.host == .codex {
                                        if marketplace.localSource {
                                            Text("Local catalog")
                                        } else {
                                            Text("Git marketplace")
                                        }
                                    }
                                    if marketplace.host == .droid, marketplace.path == nil {
                                        Text("Not fetched by Droid yet")
                                    }
                                    if marketplace.scope == "org" {
                                        Text("Organization settings")
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
                        if marketplace.host == .codex || marketplace.host == .cursor {
                            Menu {
                                Button("Refresh Marketplace") {
                                    state.manageMarketplace(
                                        marketplace, action: "marketplace-refresh")
                                }
                                Button("Remove Marketplace") {
                                    state.manageMarketplace(
                                        marketplace, action: "marketplace-remove")
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
            if [.codex, .cursor].contains(state.pluginHost), !inspectionIssues.isEmpty {
                Section {
                    DisclosureGroup("Inspection Issues") {
                        ForEach(inspectionIssues, id: \.self) { issue in
                            VStack(alignment: .leading) {
                                Text(verbatim: issue.message)
                                Text(verbatim: issue.path).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("sukiru.plugins.inspectionIssues")
                    .help("Inspect plugin inventory errors")
                }
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("sukiru.plugins.marketplace.list")
        .overlay {
            if marketplaces.isEmpty, state.pluginHost == .codex, inspectionIssues.isEmpty {
                ContentUnavailableView {
                    Label("No configured marketplaces", systemImage: "shippingbox")
                } description: {
                    Text("Add a local catalog or a Git marketplace to Codex.")
                }
            } else if marketplaces.isEmpty, state.pluginHost == .droid {
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
            } else if marketplaces.isEmpty, inspectionIssues.isEmpty {
                ContentUnavailableView {
                    Label("No cached marketplace catalog", systemImage: "shippingbox")
                } description: {
                    Text(
                        "Open \(state.pluginHost.displayName) and sign in; Sukiru reads the catalog the host caches."
                    )
                }
            } else if showsUnfetchedDroidCatalogs {
                ContentUnavailableView {
                    Label("Not fetched by Droid yet", systemImage: "shippingbox")
                } description: {
                    Text("Start Droid in a project, or refresh the marketplace in Marketplaces….")
                }
            } else if showsEmptyCatalog {
                ContentUnavailableView(
                    "The cached catalog has no listings", systemImage: "shippingbox")
            } else if !filter.isEmpty, marketplaces.allSatisfy({ entries($0).isEmpty }) {
                ContentUnavailableView.search(text: filter)
            }
        }
        .onChange(of: marketplaces) { _, visible in
            guard let selected = state.selectedCatalogEntryID else { return }
            if !visible.contains(where: { market in
                market.plugins.contains { market.catalogID($0) == selected && $0.matches(filter) }
            }) {
                state.selectedCatalogEntryID = nil
            }
        }
    }

    private var inspectionIssues: [PluginInventoryIssue] {
        (state.report?.pluginInventory?.issues ?? []).filter {
            $0.host == state.pluginHost
                && (state.pluginHost != .cursor
                    || $0.path.contains("/.cursor/plugins/marketplaces/"))
        }
    }

    private var showsEmptyCatalog: Bool {
        ![.codex, .cursor].contains(state.pluginHost) && inspectionIssues.isEmpty
            && marketplaces.allSatisfy { $0.plugins.isEmpty }
    }

    private var showsUnfetchedDroidCatalogs: Bool {
        !marketplaces.isEmpty && marketplaces.allSatisfy { $0.host == .droid && $0.path == nil }
    }

    private func codexCatalogExists(_ marketplace: PluginMarketplace) -> Bool {
        guard let root = marketplace.path else { return false }
        return [".agents/plugins/marketplace.json", ".claude-plugin/marketplace.json"].contains {
            FileManager.default.fileExists(atPath: root + "/" + $0)
        }
    }

    /// Droid identifies an installation by plugin and marketplace, so its match is exact;
    /// elsewhere only the name can match.
    private func installation(
        _ entry: PluginCatalogEntry, in marketplace: PluginMarketplace
    ) -> PluginCatalogRow.Installation? {
        let plugins = state.pluginInstallations(for: marketplace.host)
        if marketplace.host == .cursor { return nil }
        if marketplace.host == .codex {
            guard
                let plugin = plugins.first(where: {
                    $0.identifier == "\(entry.name)@\(marketplace.name)"
                        && $0.scope == marketplace.scope && $0.scopeRoot == marketplace.scopeRoot
                })
            else { return nil }
            return plugin.installationStatus == "installed" ? .installed : .configured
        }
        if marketplace.host == .droid {
            return plugins.contains { $0.identifier == "\(entry.name)@\(marketplace.name)" }
                ? .installed : nil
        }
        return plugins.contains { $0.identifier == entry.name } ? .sameName : nil
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
    enum Installation { case installed, configured, sameName }

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
                if installation == .installed {
                    Text("Installed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if installation == .configured {
                    Text("Configured reference")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if installation == .sameName {
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
