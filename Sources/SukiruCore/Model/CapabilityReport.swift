import Foundation

/// Launch-time capability detection output (architecture §4.2, D6).
///
/// The skeleton emits a schema-valid "pending" report; the M2/M3
/// `CapabilityDetector` performs the real (subprocess-based, non-blocking)
/// probes of `gh` and `npx skills`.
public struct CapabilityReport: Codable, Equatable, Sendable {
    public struct GitHubCapability: Codable, Equatable, Sendable {
        public let available: Bool
        public let version: String?
        public let meetsMinimum: Bool
    }

    public struct NpxCapability: Codable, Equatable, Sendable {
        public let resolvable: Bool
        public let skillsVersion: String?
    }

    public let schemaVersion: Int
    public let github: GitHubCapability
    public let npx: NpxCapability

    public static let currentSchemaVersion = 1

    /// A schema-valid report before detection has run.
    public static func pending() -> CapabilityReport {
        CapabilityReport(
            schemaVersion: currentSchemaVersion,
            github: GitHubCapability(available: false, version: nil, meetsMinimum: false),
            npx: NpxCapability(resolvable: false, skillsVersion: nil)
        )
    }

    /// Deterministic JSON encoding (sorted keys).
    public func jsonData() throws -> Data {
        try deterministicJSONData(self)
    }
}
