import Foundation

public struct PluginLifecycleRequest: Codable, Equatable, Sendable {
    public let host: PluginHost
    public let action: String
    public let target: String
    public let scope: String
    public let scopeRoot: String
    public let gitRef: String?
    public let marketplace: String?
    public let strict: Bool?

    public init(
        host: PluginHost, action: String, target: String, scope: String, scopeRoot: String,
        gitRef: String? = nil, marketplace: String? = nil, strict: Bool? = nil
    ) {
        self.host = host
        self.action = action
        self.target = target
        self.scope = scope
        self.scopeRoot = scopeRoot
        self.gitRef = gitRef
        self.marketplace = marketplace
        self.strict = strict
    }

    public static let actions = [
        "install", "replace", "enable", "disable", "update", "remove", "check", "list",
        "marketplace-add", "marketplace-refresh", "marketplace-remove", "disable-local",
        "import", "validate", "link"
    ]
}

public struct PluginLifecyclePlan: Codable, Sendable {
    public let batch: CommandBatch?
    public let instructions: [String]
    public let impacts: [String]
}

public struct PluginLifecycleCapabilities: Codable, Sendable {
    public let host: PluginHost
    public let version: String
    public let nativeCandidates: [String]
    public let limits: [String: String]
}

public struct PluginLifecycleError: Error, LocalizedError, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}
