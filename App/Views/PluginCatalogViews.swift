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
                    if marketplace.host == .claude, marketplace.plugins.isEmpty, filter.isEmpty {
                        Text("No locally cached plugins").foregroundStyle(.secondary)
                    }
                    if marketplace.host == .droid, marketplace.plugins.isEmpty, filter.isEmpty {
                        if marketplace.path == nil {
                            Text("Not fetched by Droid yet").foregroundStyle(.secondary)
                        } else if inspectionIssues.contains(where: {
                            $0.path.hasPrefix((marketplace.path ?? "") + "/")
                        }) {
                            Text("Catalog could not be read").foregroundStyle(.secondary)
                        } else if !droidCatalogExists(marketplace) {
                            Text("Catalog not found").foregroundStyle(.secondary)
                        } else {
                            Text("No locally cached plugins").foregroundStyle(.secondary)
                        }
                    }
                    if marketplace.host == .antigravity, marketplace.plugins.isEmpty {
                        if filter.isEmpty {
                            Text("No locally cached plugins").foregroundStyle(.secondary)
                        }
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
                            if [.droid, .codex, .claude].contains(marketplace.host) {
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
                                    if marketplace.scope == "org" {
                                        Text("Organization settings")
                                        Text("Organization settings manage this marketplace.")
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
                            if marketplace.host == .antigravity {
                                Text("Manage marketplaces in Antigravity.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if marketplace.host.managesMarketplaces {
                            Menu {
                                Button("Refresh Marketplace") {
                                    state.manageMarketplace(
                                        marketplace, action: "marketplace-refresh")
                                }
                                .accessibilityIdentifier(
                                    "sukiru.plugins.marketplace.marketplace-refresh.\(marketplace.id)"
                                )
                                .help("Preview an operation for this marketplace")
                                if marketplace.scope != "org" {
                                    Button("Remove Marketplace") {
                                        state.manageMarketplace(
                                            marketplace, action: "marketplace-remove")
                                    }
                                    .accessibilityIdentifier(
                                        "sukiru.plugins.marketplace.marketplace-remove.\(marketplace.id)"
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
            if !inspectionIssues.isEmpty {
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
            if marketplaces.isEmpty, state.pluginHost == .claude, inspectionIssues.isEmpty {
                ContentUnavailableView {
                    Label("No configured marketplaces", systemImage: "shippingbox")
                } actions: {
                    Button("Add Marketplace…") {
                        state.newPluginOperation(host: .claude, action: "marketplace-add")
                    }
                    .accessibilityIdentifier("sukiru.plugins.marketplace.add.empty")
                    .help("Preview registering a marketplace with this host")
                }
            } else if marketplaces.isEmpty, state.pluginHost == .codex, inspectionIssues.isEmpty {
                ContentUnavailableView {
                    Label("No configured marketplaces", systemImage: "shippingbox")
                } description: {
                    Text("Add a local catalog or a Git marketplace to Codex.")
                }
            } else if marketplaces.isEmpty, state.pluginHost == .droid, inspectionIssues.isEmpty {
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
                    if state.pluginHost == .antigravity {
                        Text("Manage marketplaces in Antigravity.")
                    } else {
                        Text("Add a marketplace to Cursor to see its cached catalog.")
                    }
                }
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
        .onChange(of: filter) { _, value in
            if let selected = state.selectedCatalogEntry, !selected.entry.matches(value) {
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

    /// Droid identifies an installation by plugin and marketplace, so its match is exact;
    /// elsewhere only the name can match.
    private func installation(
        _ entry: PluginCatalogEntry, in marketplace: PluginMarketplace
    ) -> PluginCatalogRow.Installation? {
        let plugins = state.pluginInstallations(for: marketplace.host)
        if marketplace.host == .cursor { return nil }
        if marketplace.host == .claude {
            let recorded = plugins.filter { $0.identifier == "\(entry.name)@\(marketplace.name)" }
            return recorded.isEmpty ? nil : .recorded(recorded)
        }
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

extension PluginCatalogList {
    fileprivate func codexCatalogExists(_ marketplace: PluginMarketplace) -> Bool {
        guard let root = marketplace.path else { return false }
        return [".agents/plugins/marketplace.json", ".claude-plugin/marketplace.json"].contains {
            FileManager.default.fileExists(atPath: root + "/" + $0)
        }
    }

    fileprivate func droidCatalogExists(_ marketplace: PluginMarketplace) -> Bool {
        guard let root = marketplace.path else { return false }
        return [".factory-plugin/marketplace.json", ".claude-plugin/marketplace.json"].contains {
            FileManager.default.fileExists(atPath: root + "/" + $0)
        }
    }
}

private struct PluginCatalogRow: View {
    enum Installation {
        case installed, configured, sameName
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
                } else if case .configured = installation {
                    Text("Configured reference")
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
