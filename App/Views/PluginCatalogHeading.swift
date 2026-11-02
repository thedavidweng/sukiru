import SukiruCore
import SwiftUI

/// A marketplace's name and one metadata line: its source, the scope that registers
/// it and the age of the cached catalog.
struct PluginCatalogHeading: View {
    let marketplace: PluginMarketplace

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            name
            caption
        }
    }

    @ViewBuilder
    private var name: some View {
        if marketplace.host == .antigravity {
            Text(verbatim: marketplace.name)
                .help("Manage marketplaces in Antigravity.")
        } else {
            Text(verbatim: marketplace.displayName ?? marketplace.name)
        }
    }

    private var caption: some View {
        HStack(spacing: 6) {
            if marketplace.isCursorOfficialCatalog {
                // The repository holds part of the official catalog; the rest is only on
                // Cursor's own page.
                Text("Complete catalog at")
                Link(destination: Self.catalogPage) {
                    Text(verbatim: "cursor.com/marketplace")
                }
                .foregroundStyle(.tint)
                .help("Cursor lists every plugin in its catalog on cursor.com/marketplace")
                .accessibilityIdentifier(
                    "sukiru.plugins.marketplace.catalogPage.\(marketplace.id)")
            } else {
                if let source {
                    Text(verbatim: source)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(sourceHelp)
                        .accessibilityIdentifier(
                            "sukiru.plugins.marketplace.source.\(marketplace.id)")
                }
                scope
                if let updated = marketplace.updatedDate {
                    Text("Updated \(updated, format: .relative(presentation: .named))")
                        .help(updated.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private static let catalogPage = URL(string: "https://cursor.com/marketplace")!

    /// Antigravity lists Google-hosted catalogs, so it has no source to show.
    private var source: String? {
        guard marketplace.host != .antigravity else { return nil }
        // The Git URL a Cursor marketplace was registered from identifies it; the indexed
        // commit is detail for the help.
        guard marketplace.host != .cursor else { return marketplace.source }
        return marketplace.source + (marketplace.ref.map { " · " + $0 } ?? "")
    }

    private var sourceHelp: String {
        var parts: [String] = []
        if marketplace.host == .codex {
            parts.append(
                marketplace.localSource
                    ? String(localized: "Local catalog") : String(localized: "Git marketplace"))
        }
        parts.append(marketplace.source)
        if let ref = marketplace.ref {
            parts.append(String(localized: "Git ref: \(ref)"))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var scope: some View {
        let project = URL(fileURLWithPath: marketplace.scopeRoot).lastPathComponent
        if marketplace.isCursorRegistration {
            Text(cursorScope)
        } else {
            switch (marketplace.host, marketplace.scope) {
            case (.cursor, _), (.antigravity, _):
                EmptyView()
            case (.claude, "user") where marketplace.evidence == "cached-catalog":
                Text("User scope")
                    .help(
                        "No settings file declares this marketplace, so Claude Code added it in user scope"
                    )
            case (_, "org"):
                Text("Organization settings")
            case (_, "user"):
                Text("User scope")
            case (_, "project"):
                Text(verbatim: project)
                    .help(marketplace.scopeRoot)
            case (_, "local"):
                Text(verbatim: project)
                    .help(String(localized: "Local project settings: \(marketplace.scopeRoot)"))
            default:
                EmptyView()
            }
        }
    }

    /// Cursor reports the level each marketplace is registered at; only a user registration
    /// belongs to this Mac's account.
    private var cursorScope: LocalizedStringKey {
        switch marketplace.scope {
        case "user": "User scope"
        case "team": "Team scope"
        default: "Global scope"
        }
    }
}
