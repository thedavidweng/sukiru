import Foundation

public enum PluginHost: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case opencode
    case cursor
    case antigravity

    public var executable: String {
        switch self {
        case .cursor: "agent"
        case .antigravity: "agy"
        default: rawValue
        }
    }
}

public enum PluginEnablement: String, Codable, Sendable {
    case enabled
    case disabled
    case unknown
}

/// Inventory and configured enablement do not establish runtime loading.
public struct PluginInstallation: Codable, Equatable, Sendable, Identifiable {
    public let host: PluginHost
    public let source: String
    public let identifier: String
    public let scope: String
    public let scopeRoot: String
    public let version: String?
    public let path: String?
    public let enablement: PluginEnablement
    public let loadStatus: String
    public let components: [PluginComponent]
    public let installationStatus: String
    public let format: String?
    public let name: String?
    /// The plugin's own one-line description, from its manifest.
    public let summary: String?
    /// The manifest's icon: a file inside the plugin, or an HTTPS address.
    public let logo: String?

    public let id: String

    init(
        host: PluginHost, source: String, identifier: String, scope: String, scopeRoot: String,
        version: String?, path: String?, enablement: PluginEnablement, loadStatus: String,
        components: [PluginComponent], installationStatus: String = "recorded",
        format: String? = nil, name: String? = nil, details: PluginManifestDetails = .init()
    ) {
        self.host = host
        self.source = source
        self.identifier = identifier
        self.scope = scope
        self.scopeRoot = scopeRoot
        self.version = version
        self.path = path
        self.enablement = enablement
        self.loadStatus = loadStatus
        self.components = components
        self.format = format
        self.name = name
        self.summary = details.summary
        self.logo = details.logo
        self.installationStatus = installationStatus
        self.id =
            ([host.rawValue, source, identifier, scope, scopeRoot]
            + ([.cursor, .antigravity].contains(host) ? [path ?? ""] : []))
            .map { "\($0.utf8.count):\($0)" }.joined()
    }
}

/// What a plugin's manifest says about itself, for display only.
struct PluginManifestDetails {
    var summary: String?
    var logo: String?

    init(summary: String? = nil, logo: String? = nil) {
        self.summary = summary
        self.logo = logo
    }

    /// Codex's `interface` block first, then the keys Claude, Cursor and
    /// Antigravity manifests share. A relative logo must stay inside `root`.
    init(_ manifest: [String: Any]?, root: String?) {
        let interface = manifest?["interface"] as? [String: Any]
        let text = { (value: Any?) in (value as? String).flatMap { $0.isEmpty ? nil : $0 } }
        summary = text(interface?["shortDescription"]) ?? text(manifest?["description"])
        let address =
            text(interface?["logo"]) ?? text(interface?["composerIcon"]) ?? text(manifest?["logo"])
            ?? text(manifest?["icon"])
        guard let address else { return }
        if address.hasPrefix("https://") {
            logo = address
        } else if let root, !address.contains("://") {
            let boundary = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
            let file = boundary.appendingPathComponent(address).resolvingSymlinksInPath()
                .standardizedFileURL.path
            if file.hasPrefix(boundary.path + "/"), FileManager.default.fileExists(atPath: file) {
                logo = file
            }
        }
    }
}

public struct PluginComponent: Codable, Equatable, Sendable {
    public let kind: String
    public let name: String
    public let path: String?
}

public struct PluginMarketplace: Codable, Equatable, Sendable, Identifiable {
    public let host: PluginHost
    public let name: String
    public let source: String
    public let scopeRoot: String
    public let path: String?
    public let plugins: [PluginCatalogEntry]
    public var evidence: String?
    /// The settings scope that declares the marketplace (`user`, `project`,
    /// or Claude's `local`); a declaration in each scope is its own entry.
    public var scope: String = "user"
    /// The Git ref a host records for the marketplace source, when any.
    public var ref: String?
    /// A local directory used in place; hosts do not fetch or upgrade it.
    public var localSource = false
    /// When the host last fetched a cached catalog, as the host records it.
    public var updatedAt: String?

    public var id: String {
        "\(host.rawValue):\(scopeRoot):\(name)"
            + (scope == "local" ? ":local" : "")
            + (host == .cursor ? ":" + (path ?? "") : "")
    }
}

/// Listing details are what the catalog declares; they are not evidence of an installation.
public struct PluginCatalogEntry: Codable, Equatable, Sendable {
    public let name: String
    public let source: String
    public let version: String?
    public var displayName: String?
    public var summary: String?
    /// The listing's icon address as the catalog declares it.
    public var logo: String?
    public var author: String?
    public var homepage: String?
    public var repository: String?
    public var license: String?
    public var categories: [String]?
    public var keywords: [String]?
    public var suggestedPrompts: [String]?
}

/// An inventory read error attributed to the host whose files produced it.
public struct PluginInventoryIssue: Codable, Hashable, Sendable {
    public let host: PluginHost
    public let kind: String
    public let path: String
    public let message: String

    init(host: PluginHost, _ issue: Issue) {
        self.host = host
        self.kind = issue.kind
        self.path = issue.path
        self.message = issue.message
    }
}

public struct PluginInventory: Codable, Equatable, Sendable {
    public let installations: [PluginInstallation]
    public let marketplaces: [PluginMarketplace]
    public let issues: [PluginInventoryIssue]
    public let healthFindings: [PluginHealthFinding]

    public init(
        installations: [PluginInstallation], marketplaces: [PluginMarketplace],
        issues: [PluginInventoryIssue],
        healthFindings: [PluginHealthFinding] = []
    ) {
        self.installations = installations
        self.marketplaces = marketplaces
        self.issues = issues
        self.healthFindings = healthFindings
    }

    public var isEmpty: Bool { installations.isEmpty && marketplaces.isEmpty && issues.isEmpty }
}
