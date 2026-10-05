import SukiruCore
import SwiftUI

struct PluginMarketplacesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    let marketplaces: [PluginMarketplace]
    let onInstall: (PluginCatalogEntry, PluginMarketplace) -> Void
    let onManage: (PluginMarketplace, String) -> Void

    private var visibleMarketplaces: [PluginMarketplace] {
        marketplaces.filter { marketplace in
            filter.isEmpty
                || marketplace.plugins.contains { $0.name.localizedCaseInsensitiveContains(filter) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Marketplaces").font(.title2.weight(.semibold))
            TextField("Filter Plugins", text: $filter)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("sukiru.plugins.catalog.filter")
                .help("Search plugin names in configured marketplaces")
            List {
                ForEach(visibleMarketplaces) { marketplace in
                    Section {
                        ForEach(
                            marketplace.plugins.filter {
                                filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)
                            }, id: \.name
                        ) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: entry.name)
                                        .font(.body.weight(.semibold))
                                    if let version = entry.version {
                                        Text(verbatim: version)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button("Install…") { onInstall(entry, marketplace) }
                                    .accessibilityIdentifier(
                                        "sukiru.plugins.catalog.install.\(entry.name)"
                                    )
                                    .help("Preview installation from this configured marketplace")
                            }
                        }
                        if marketplace.plugins.isEmpty {
                            Text("No locally cached plugins")
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: marketplace.name)
                                if marketplace.evidence == "cached-catalog" {
                                    Text("Cached catalog; registration scope unknown")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    scopeLabel(marketplace)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(verbatim: marketplace.source)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                let actions = ["marketplace-refresh", "marketplace-remove"]
                                ForEach(actions, id: \.self) { action in
                                    Button(PluginActionTitle.title(action)) {
                                        onManage(marketplace, action)
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
                            .labelStyle(.iconOnly)
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Preview an operation for this marketplace")
                        }
                    }
                    .accessibilityIdentifier("sukiru.plugins.marketplace.\(marketplace.id)")
                }
            }
            .listStyle(.inset)
            .overlay {
                if marketplaces.isEmpty {
                    ContentUnavailableView("No configured marketplaces", systemImage: "shippingbox")
                } else if visibleMarketplaces.isEmpty {
                    ContentUnavailableView.search(text: filter)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("sukiru.plugins.catalog.done")
                    .help("Close marketplace browsing")
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 420, idealHeight: 540)
    }

    private func scopeLabel(_ marketplace: PluginMarketplace) -> Text {
        switch marketplace.scope {
        case "user": Text("User Library")
        case "local": Text("Local project settings: \(marketplace.scopeRoot)")
        default: Text(verbatim: marketplace.scopeRoot)
        }
    }
}
