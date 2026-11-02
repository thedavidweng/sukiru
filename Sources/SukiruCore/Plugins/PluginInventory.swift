import Foundation

public enum PluginHost: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case opencode
    case cursor
    case antigravity
    case droid

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
    public var plugins: [PluginCatalogEntry]
    public var evidence: String?
    /// The name the host shows for the marketplace when it differs from the identifier.
    public var displayName: String?
    /// The settings scope that declares the marketplace (`user`, `project`,
    /// Claude's `local` or Droid's `org`); a declaration in each scope is its own entry.
    public var scope: String = "user"
    /// The Git ref a host records for the marketplace source, when any.
    public var ref: String?
    /// A local directory used in place; hosts do not fetch or upgrade it.
    public var localSource = false
    /// When the host last fetched a cached catalog, as the host records it.
    public var updatedAt: String?
    /// The source type recorded by the host, when present.
    public var sourceType: String?
    public var catalogState: String?

    struct SourceIdentity: Hashable {
        let source: String
        let ref: String?
        let type: String?
    }

    var sourceIdentity: SourceIdentity {
        SourceIdentity(
            source: localSource
                ? URL(fileURLWithPath: path ?? source, relativeTo: URL(fileURLWithPath: scopeRoot))
                    .resolvingSymlinksInPath().path : source,
            ref: ref, type: sourceType)
    }

    public var id: String {
        "\(host.rawValue):\(scopeRoot):\(name)"
            + (["local", "org"].contains(scope) ? ":" + scope : "")
            + (host == .cursor ? ":" + (path ?? "") : "")
            + (host == .claude
                ? ":\(source.utf8.count):\(source):\(ref ?? ""):\(sourceType ?? "")" : "")
            + (host == .codex
                ? ":\(source.utf8.count):\(source):\(ref ?? ""):\(localSource)" : "")
    }

    /// Droid records an ISO 8601 cache time and Antigravity an HTTP date; `updatedAt`
    /// keeps the host's string for the CLI.
    public var updatedDate: Date? {
        guard let updatedAt else { return nil }
        if let date = Self.iso8601(updatedAt) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: updatedAt)
    }

    private static func iso8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
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

    func claudeHasUniqueSource(_ name: String) -> Bool {
        Set(marketplaces.filter { $0.host == .claude && $0.name == name }.map(\.sourceIdentity))
            .count == 1
    }

    public func recordedClaudeInstallations(
        _ entry: PluginCatalogEntry, marketplace: PluginMarketplace
    ) -> [PluginInstallation] {
        guard marketplace.host == .claude, claudeHasUniqueSource(marketplace.name) else {
            return []
        }
        return installations.filter {
            $0.host == .claude && $0.identifier == "\(entry.name)@\(marketplace.name)"
        }
    }

    /// The listing that describes an installation well enough to lend it a name and
    /// icon. Claude, Codex and Droid record `plugin@marketplace`, so their match is
    /// exact. Antigravity and Cursor record only a plugin name, which matches when
    /// exactly one listing carries that name; such a match is display only and is
    /// no evidence that the installation came from that listing.
    public func catalogEntry(for installation: PluginInstallation) -> PluginCatalogEntry? {
        switch installation.host {
        case .claude, .codex, .droid:
            guard let (plugin, name) = PluginInventoryReader.droidPluginID(installation.identifier)
            else { return nil }
            guard installation.host != .claude || claudeHasUniqueSource(name) else { return nil }
            let marketplace = marketplaces.first {
                $0.host == installation.host && $0.name == name
                    && (installation.host != .codex
                        || ($0.scope == installation.scope
                            && $0.scopeRoot == installation.scopeRoot))
                    && $0.plugins.contains { $0.name == plugin }
            }
            return marketplace?.plugins.first { $0.name == plugin }
        case .antigravity, .cursor:
            let listings = marketplaces.filter { $0.host == installation.host }
                .flatMap { $0.plugins.filter { $0.name == installation.identifier } }
            return listings.count == 1 ? listings[0] : nil
        case .opencode:
            return nil
        }
    }

    /// Cursor installs the official catalog's plugins into a cache folder named after the
    /// registration of that marketplace, so a cached payload with the listing's name in that
    /// folder is the local evidence an official listing was installed.
    public func cursorHasInstalled(
        _ entry: PluginCatalogEntry, in marketplace: PluginMarketplace
    ) -> Bool {
        marketplace.isCursorOfficialCatalog
            && installations.contains {
                $0.host == .cursor && $0.source == marketplace.name
                    && $0.identifier == entry.name
            }
    }
}
