import Foundation

/// The shared retention policy for snapshots and execution records. It lives
/// in `<home>/Library/Application Support/Sukiru/settings.json` so the app
/// and the CLI apply the same limits. A missing or unreadable file, or an
/// unreadable field, falls back to the defaults.
public struct RetentionPolicy: Codable, Equatable, Sendable {
    public static let defaultMaxBatches = 20
    public static let defaultMaxAgeDays = 30
    public static let defaultMaxSizeMegabytes = 1024

    /// Keep at most this many batches.
    public var maxBatches: Int
    /// Drop batches older than this many days.
    public var maxAgeDays: Int
    /// Keep the snapshot store under this many megabytes (1 MB = 1,048,576 bytes).
    public var maxSizeMegabytes: Int

    public static let `default` = RetentionPolicy()

    public init(
        maxBatches: Int = defaultMaxBatches,
        maxAgeDays: Int = defaultMaxAgeDays,
        maxSizeMegabytes: Int = defaultMaxSizeMegabytes
    ) {
        self.maxBatches = max(1, maxBatches)
        self.maxAgeDays = max(1, maxAgeDays)
        self.maxSizeMegabytes = max(1, maxSizeMegabytes)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maxBatches: (try? container.decode(Int.self, forKey: .maxBatches))
                ?? Self.defaultMaxBatches,
            maxAgeDays: (try? container.decode(Int.self, forKey: .maxAgeDays))
                ?? Self.defaultMaxAgeDays,
            maxSizeMegabytes: (try? container.decode(Int.self, forKey: .maxSizeMegabytes))
                ?? Self.defaultMaxSizeMegabytes)
    }

    var maxSizeBytes: Int64 { Int64(maxSizeMegabytes) * 1_048_576 }
}

/// Reads and writes `settings.json`. Only the retention policy lives there
/// today, under the `retention` key.
public struct SukiruSettingsStore: Sendable {
    private struct File: Codable {
        var retention: RetentionPolicy?
    }

    private let environment: SukiruEnvironment

    public init(environment: SukiruEnvironment) {
        self.environment = environment
    }

    public func settingsPath() -> String {
        HostPathResolver.join(environment.home, "Library/Application Support/Sukiru/settings.json")
    }

    /// The stored policy, or the defaults when the file is missing or corrupt.
    public func retentionPolicy() -> RetentionPolicy {
        guard let data = FileManager.default.contents(atPath: settingsPath()),
            let file = try? JSONDecoder().decode(File.self, from: data)
        else {
            return .default
        }
        return file.retention ?? .default
    }

    public func save(_ policy: RetentionPolicy) throws {
        let path = settingsPath()
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
            withIntermediateDirectories: true)
        let data = try deterministicJSONData(File(retention: policy))
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
