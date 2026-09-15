import Foundation

/// Read-only access to environment variables.
///
/// This is the single seam through which Sukiru reads environment overrides,
/// so tests can supply values without mutating the real process environment.
public protocol EnvironmentReader: Sendable {
    func value(for key: String) -> String?
}

/// Reads variables from the current process environment.
public struct ProcessEnvironmentReader: EnvironmentReader {
    public init() {}

    public func value(for key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }
}

/// In-memory reader backed by a fixed dictionary, for tests.
public struct DictionaryEnvironmentReader: EnvironmentReader {
    private let values: [String: String]

    public init(_ values: [String: String]) {
        self.values = values
    }

    public func value(for key: String) -> String? {
        values[key]
    }
}
