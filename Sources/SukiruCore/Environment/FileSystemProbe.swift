import Foundation

/// Read-only filesystem facts, injectable so detection and enumeration logic
/// can be tested without touching the real disk.
///
/// `isFile` / `isDirectory` FOLLOW symlinks (matching the Rust archive's
/// `Path::is_file` / `Path::is_dir`), so a symlink to a directory reports as a
/// directory. `directoryEntries` returns the child names of a directory
/// (including hidden entries such as `.DS_Store`), or `nil` when the path is
/// not a directory or cannot be read.
public protocol FileSystemProbe: Sendable {
    func exists(atPath path: String) -> Bool
    func isFile(atPath path: String) -> Bool
    func isDirectory(atPath path: String) -> Bool
    func directoryEntries(atPath path: String) -> [String]?
    /// The bytes of a regular file, or nil when it cannot be read. Never
    /// throws: unreadable files are data (Issue records), not failures.
    func fileContents(atPath path: String) -> Data?
}

/// Probes the real filesystem via `FileManager`.
public struct DefaultFileSystemProbe: FileSystemProbe {
    public init() {}

    public func exists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func isFile(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && !isDir.boolValue
    }

    public func isDirectory(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    public func directoryEntries(atPath path: String) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: path)
    }

    public func fileContents(atPath path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }
}
