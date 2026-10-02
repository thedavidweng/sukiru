import Foundation

/// Why gh is unavailable (two states, but the reason is shown).
/// Nil on the report iff `available` is true.
public enum GitHubUnavailableReason: String, Codable, Equatable, Sendable {
    /// No gh answered `gh --version` with a parseable version.
    case absent
    /// gh is present but below the 2.90.0 `gh skill` floor.
    case tooOld = "too-old"
    /// gh meets the version floor but `gh skill --help` failed.
    case probeFailed = "probe-failed"
}

/// Why `npx skills` is not resolvable. Nil on the report iff `resolvable`.
public enum NpxUnavailableReason: String, Codable, Equatable, Sendable {
    /// No npx on PATH (Node.js is not installed).
    case absent
    /// npx works, but the skills CLI has not been downloaded to this Mac yet.
    /// npx fetches it when the first confirmed command needs it (or when the
    /// user downloads it from Settings), never on its own.
    case notDownloaded = "not-downloaded"
}

/// Launch-time capability detection output, produced
/// by `CapabilityDetector`. NEVER part of ScanReport: capabilities are
/// the sole command allowed to spawn probe subprocesses.
public struct CapabilityReport: Codable, Equatable, Sendable {
    public struct GitHubCapability: Codable, Equatable, Sendable {
        /// Two-state verdict: present AND ≥ 2.90.0 AND `gh skill` probe OK.
        public let available: Bool
        /// A gh executable answered `gh --version` with a parseable version.
        public let present: Bool
        public let version: String?
        public let meetsMinimum: Bool
        /// Why gh is unavailable; omitted from the JSON when available.
        public let reason: GitHubUnavailableReason?
    }

    public struct NpxCapability: Codable, Equatable, Sendable {
        public let resolvable: Bool
        public let skillsVersion: String?
        /// Why npx skills is not resolvable; omitted from the JSON when it is.
        public let reason: NpxUnavailableReason?

        /// Whether `npx skills` commands can run: npx is present, so a
        /// missing CLI is downloaded by the first command that needs it.
        public var canRunSkills: Bool { reason != .absent }
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
                available: false, present: false, version: nil, meetsMinimum: false,
                reason: .absent),
            npx: NpxCapability(resolvable: false, skillsVersion: nil, reason: .absent)
        )
    }

    /// Deterministic JSON encoding (sorted keys).
    public func jsonData() throws -> Data {
        try deterministicJSONData(self)
    }
}
