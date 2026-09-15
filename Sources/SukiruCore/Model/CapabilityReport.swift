import Foundation

/// Launch-time capability detection output (architecture §4.2, D6), produced
/// by `CapabilityDetector`. NEVER part of ScanReport (D2): capabilities are
/// the sole command allowed to spawn probe subprocesses.
public struct CapabilityReport: Codable, Equatable, Sendable {
    public struct GitHubCapability: Codable, Equatable, Sendable {
        /// D6 two-state verdict: present AND ≥ 2.90.0 AND `gh skill` probe OK.
        public let available: Bool
        /// A gh executable answered `gh --version` with a parseable version.
        public let present: Bool
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
            github: GitHubCapability(
                available: false, present: false, version: nil, meetsMinimum: false),
            npx: NpxCapability(resolvable: false, skillsVersion: nil)
        )
    }

    /// Deterministic JSON encoding (sorted keys).
    public func jsonData() throws -> Data {
        try deterministicJSONData(self)
    }
}
