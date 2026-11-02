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
            if !readProblems.isEmpty || isReadingCursor {
                Section {
                    ForEach(readProblems, id: \.self) { problem in
                        Text(verbatim: problem)
                            .foregroundStyle(.secondary)
                    }
                    if isReadingCursor {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading Cursor's marketplaces…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("sukiru.plugins.marketplace.readState")
            }
            ForEach(marketplaces.filter { filter.isEmpty || !entries($0).isEmpty }) { marketplace in
                let cachedClaude =
                    marketplace.host == .claude && marketplace.evidence == "cached-catalog"
                let showsEmpty =
                    filter.isEmpty || [.cursor, .antigravity].contains(marketplace.host)
                Section {
                    HStack(alignment: .top) {
                        PluginCatalogHeading(marketplace: marketplace)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if marketplace.allowsMarketplaceActions {
                            Menu {
                                Button("Refresh Marketplace") {
                                    state.manageMarketplace(
                                        marketplace, action: "marketplace-refresh")
                                }
                                .accessibilityIdentifier(
                                    "sukiru.plugins.marketplace.marketplace-refresh.\(marketplace.id)"
                                )
                                .help("Preview an operation for this marketplace")
                                if marketplace.scope != "org", !cachedClaude {
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
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier(
                                "sukiru.plugins.marketplace.actions.\(marketplace.id)"
                            )
                            .help("Preview an operation for this marketplace")
                            .fixedSize()
                        }
                    }
                    ForEach(entries(marketplace), id: \.name) { entry in
                        PluginCatalogRow(
                            entry: entry, installation: installation(entry, in: marketplace)
                        )
                        .tag(marketplace.catalogID(entry))
                    }
                    if marketplace.plugins.isEmpty, showsEmpty {
                        Text(emptyCatalogMessage(marketplace)).foregroundStyle(.secondary)
                    }
                }
            }
            if showsFilteredEmpty, !inspectionIssues.isEmpty {
                ContentUnavailableView.search(text: filter)
            }
            if !inspectionIssues.isEmpty {
                Section {
                    DisclosureGroup("Inspection Issues") {
                        ForEach(inspectionIssues, id: \.self) { issue in
                            VStack(alignment: .leading) {
                                Text(verbatim: UserFacingError.message(for: issue))
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
                    Button("Add Factory Plugins…") { state.addFactoryMarketplace() }
                        .disabled(state.pluginActionsBusy)
                        .accessibilityIdentifier("sukiru.plugins.marketplace.add.official")
                        .help("Preview registering Factory's official marketplace")
                }
            } else if marketplaces.isEmpty, inspectionIssues.isEmpty, !isReadingCursor {
                ContentUnavailableView {
                    Label("No cached marketplace catalog", systemImage: "shippingbox")
                } description: {
                    if state.pluginHost == .antigravity {
                        Text("Manage marketplaces in Antigravity.")
                    } else {
                        Text("Refresh to list the marketplaces Cursor has registered.")
                    }
                }
            } else if showsFilteredEmpty, inspectionIssues.isEmpty {
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

    private func emptyCatalogMessage(_ marketplace: PluginMarketplace) -> LocalizedStringKey {
        if marketplace.host == .cursor {
            return marketplace.isCursorRegistration && marketplace.path == nil
                ? "Not cached" : "The cached catalog has no listings"
        }
        switch marketplace.catalogState {
        case "unverified":
            return marketplace.host == .codex && marketplace.scope == "user"
                ? "Refresh Marketplace to verify the cached source."
                : "Catalog source could not be verified"
        case "unreadable": return "Catalog could not be read"
        case "not-fetched": return "Not fetched by Droid yet"
        case "missing": return "Catalog not found"
        default:
            if marketplace.host == .codex, marketplace.catalogState != "available" {
                return "Catalog not found"
            }
            return "No locally cached plugins"
        }
    }

    /// Droid identifies an installation by plugin and marketplace, so its match is exact;
    /// elsewhere only the name can match.
    private func installation(
        _ entry: PluginCatalogEntry, in marketplace: PluginMarketplace
    ) -> PluginCatalogRow.Installation? {
        let plugins = state.pluginInstallations(for: marketplace.host)
        if marketplace.host == .cursor {
            let installed =
                state.report?.pluginInventory?.cursorHasInstalled(entry, in: marketplace)
            return installed == true ? .installed(help: nil) : nil
        }
        if marketplace.host == .claude {
            let recorded =
                state.report?.pluginInventory?.recordedClaudeInstallations(
                    entry, marketplace: marketplace) ?? []
            return recorded.isEmpty ? nil : .installed(help: recordedScopes(recorded))
        }
        if marketplace.host == .codex {
            guard
                let plugin = plugins.first(where: {
                    $0.identifier == "\(entry.name)@\(marketplace.name)"
                        && $0.scope == marketplace.scope && $0.scopeRoot == marketplace.scopeRoot
                })
            else { return nil }
            return plugin.installationStatus == "installed"
                ? .installed(help: nil) : .configured
        }
        if marketplace.host == .droid {
            return plugins.contains { $0.identifier == "\(entry.name)@\(marketplace.name)" }
                ? .installed(help: nil) : nil
        }
        return plugins.contains { $0.identifier == entry.name }
            ? .installed(
                help:
                    "An installed plugin has this directory name; that does not prove it came from this listing"
            ) : nil
    }

    /// Claude Code records the scopes it installed a plugin in; a listing's name alone does not.
    private func recordedScopes(_ records: [PluginInstallation]) -> String {
        let scopes = records.map { record in
            switch record.scope {
            case "user": String(localized: "User scope")
            case "project", "local": URL(fileURLWithPath: record.scopeRoot).lastPathComponent
            default: record.scope
            }
        }
        return String(
            localized:
                "Claude Code records this plugin as installed in \(scopes.formatted(.list(type: .and)))"
        )
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
    fileprivate var showsFilteredEmpty: Bool {
        !filter.isEmpty && marketplaces.allSatisfy { entries($0).isEmpty }
    }

    fileprivate var inspectionIssues: [PluginInventoryIssue] {
        (state.report?.pluginInventory?.issues ?? []).filter {
            $0.host == state.pluginHost
                && (state.pluginHost != .cursor
                    || $0.path.contains("/.cursor/plugins/marketplaces/"))
        }
    }

    /// The page states what an explicit Refresh could not read rather than showing the
    /// part that answered as if it were the whole list.
    fileprivate var readProblems: [String] {
        guard state.pluginHost == .cursor else { return [] }
        var problems: [String] = []
        if state.cursorCatalog.registrationsUnavailable {
            problems.append(
                String(localized: "Cursor's registered marketplaces could not be read."))
        }
        if state.cursorCatalog.officialUnavailable {
            problems.append(String(localized: "The official Cursor catalog could not be loaded."))
        }
        return problems
    }

    fileprivate var isReadingCursor: Bool {
        state.pluginHost == .cursor && state.cursorCatalog.loading
    }
}

private struct PluginCatalogRow: View {
    enum Installation {
        /// `help` carries the nuance of a name-only or host-recorded match.
        case installed(help: String?)
        case configured
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
                status
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

    @ViewBuilder
    private var status: some View {
        switch installation {
        case .installed(let help):
            if let help {
                installed.help(help)
            } else {
                installed
            }
        case .configured:
            Text("Configured reference")
                .font(.caption)
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    private var installed: Text {
        Text("Installed")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
