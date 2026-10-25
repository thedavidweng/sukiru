import Foundation

/// A package-wide pnpm permission decision, separate from installed skills and health problems.
public struct PnpmObservation: Codable, Equatable, Sendable {
    public enum Permission: String, Codable, Equatable, Sendable {
        case pending
        case approved
        case denied
        case unknown
    }

    public let projectRoot: String
    public let packageName: String
    public let selector: String
    public let permission: Permission
    /// True only when the ownership reader verified at least one placement for this package.
    public let installed: Bool
    public let metadataPath: String

    public var identity: String { projectRoot + "\u{1F}" + selector }

    public init(
        projectRoot: String, packageName: String, selector: String,
        permission: Permission, installed: Bool, metadataPath: String
    ) {
        self.projectRoot = projectRoot
        self.packageName = packageName
        self.selector = selector
        self.permission = permission
        self.installed = installed
        self.metadataPath = metadataPath
    }
}
