import Foundation

public enum PluginHost: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case opencode
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

    public let id: String

    init(
        host: PluginHost, source: String, identifier: String, scope: String, scopeRoot: String,
        version: String?, path: String?, enablement: PluginEnablement, loadStatus: String,
        components: [PluginComponent], installationStatus: String = "recorded"
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
        self.installationStatus = installationStatus
        self.id = [host.rawValue, source, identifier, scope, scopeRoot]
            .map { "\($0.utf8.count):\($0)" }.joined()
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

    public var id: String { "\(host.rawValue):\(scopeRoot):\(name)" }
}

public struct PluginCatalogEntry: Codable, Equatable, Sendable {
    public let name: String
    public let source: String
    public let version: String?
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

    init(
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
