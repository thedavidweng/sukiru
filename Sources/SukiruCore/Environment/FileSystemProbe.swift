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
    /// exist or cannot be inspected. Does NOT follow symlinks.
    func entryKind(atPath path: String) -> EntryKind?
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
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
            else {
                return .other
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
}
