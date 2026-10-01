import Foundation

/// lstat-style classification of one directory entry: symlinks report as
/// `.symlink` with their UNRESOLVED target string (matching Node's
/// `Dirent.isSymbolicLink()` + `readlink`), never followed.
public enum EntryKind: Equatable, Sendable {
    case file
    case directory
    case symlink(target: String)
    /// FIFOs, sockets, devices — never hashed, like upstream.
    case other
}

/// Read-only filesystem facts, injectable so detection and enumeration logic
/// can be tested without touching the real disk.
///
/// `isFile` / `isDirectory` FOLLOW symlinks (matching the Rust archive's
/// `Path::is_file` / `Path::is_dir`), so a symlink to a directory reports as a
/// directory. `entryKind` is the lstat-style counterpart that does NOT follow.
/// `directoryEntries` returns the child names of a directory (including hidden
/// entries such as `.DS_Store`), or `nil` when the path is not a directory or
/// cannot be read.
public protocol FileSystemProbe: Sendable {
    func exists(atPath path: String) -> Bool
    func isFile(atPath path: String) -> Bool
    func isDirectory(atPath path: String) -> Bool
    func directoryEntries(atPath path: String) -> [String]?
    /// The bytes of a regular file, or nil when it cannot be read. Never
    /// throws: unreadable files are data (Issue records), not failures.
    func fileContents(atPath path: String) -> Data?
    /// lstat-style kind of the entry at `path`, or nil when the path does not
    /// exist or cannot be inspected — including a symlink whose target string
    /// cannot be read (readlink failure), which is uninspectable, never
    /// `.other`. Does NOT follow symlinks.
    func entryKind(atPath path: String) -> EntryKind?
    /// Full canonical resolution of `path` (realpath(3) semantics: every
    /// component resolved, absolute result), or nil when the path does not
    /// exist or cannot be resolved. `URL.resolvingSymlinksInPath` is NOT a
    /// substitute — it never errors on missing paths and disagrees with
    /// realpath on `/var` vs `/private/var`.
    func resolvedPath(atPath path: String) -> String?
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

    public func entryKind(atPath path: String) -> EntryKind? {
        // attributesOfItem uses lstat semantics for the final path component:
        // a symlink reports .typeSymbolicLink rather than its target's type.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let type = attributes[.type] as? FileAttributeType
        else {
            return nil
        }
        switch type {
        case .typeSymbolicLink:
            // A symlink whose target string cannot be read (readlink failure
            // — e.g. a mid-scan replacement race) is UNINSPECTABLE, not
            // `.other`: returning nil lets callers surface an issue instead
            // of silently dropping the entry (failure-as-data convention).
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
            else {
                return nil
            }
            return .symlink(target: target)
        case .typeDirectory:
            return .directory
        case .typeRegular:
            return .file
        default:
            return .other
        }
    }

    public func resolvedPath(atPath path: String) -> String? {
        guard let resolved = path.withCString({ realpath($0, nil) }) else {
            return nil
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
