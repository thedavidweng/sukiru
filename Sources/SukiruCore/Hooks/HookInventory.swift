import Foundation

public enum HookHealth: String, Codable, Sendable {
    case observed, brokenTarget, leftover, externallyManaged, sourceManaged, invalid, unknown

    public var isProblem: Bool { [.brokenTarget, .leftover, .invalid].contains(self) }
}

public struct HookSource: Codable, Equatable, Sendable {
    public let host: PluginHost
    public let path: String
    public let tier: String
    public let definitionRoot: [String]
    public let scope: String
    public let scopeRoot: String
    public let managingPluginID: String?
    public let managingSource: String?
    public let contentHash: String
    public let resolvedPath: String
    public let writable: Bool
}

public struct HookAttribution: Codable, Equatable, Sendable {
    public let producer: String
    public let evidence: [String]
    public let producerPresent: Bool?
}

/// One configured handler, with its exact structural identity, not runtime status.
public struct AgentHook: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let source: HookSource
    public let event: String
    public let matcher: String?
    public let handlerType: String
    public let details: [String: JSONValue]
    public let groupIndex: Int
    public let handlerIndex: Int
    public let attribution: HookAttribution
    public let health: HookHealth
    public let evidence: [String]
    public let targets: [String]
    public let trust: String

    public var canRemove: Bool { source.writable && health != .invalid }
}

public struct HookInventoryIssue: Codable, Equatable, Sendable, Identifiable {
    public let host: PluginHost
    public let path: String
    public let scopeRoot: String
    public let message: String
    public var id: String { host.rawValue + ":" + path + ":" + message }
}

public struct HookInventory: Codable, Equatable, Sendable {
    public let hooks: [AgentHook]
    public let issues: [HookInventoryIssue]
    public init(hooks: [AgentHook], issues: [HookInventoryIssue]) {
        self.hooks = hooks
        self.issues = issues
    }

    public var problems: [AgentHook] { hooks.filter { $0.health.isProblem } }
    public var isEmpty: Bool { hooks.isEmpty && issues.isEmpty }
}

public struct HookError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
