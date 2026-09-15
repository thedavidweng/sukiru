import Foundation

/// Minimal path-existence probe, injectable so exit-code logic can be tested
/// without touching the real filesystem.
public protocol FileSystemProbe: Sendable {
    func exists(atPath path: String) -> Bool
}

/// Probes the real filesystem via `FileManager`.
public struct DefaultFileSystemProbe: FileSystemProbe {
    public init() {}

    public func exists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
