import Foundation

/// The direct file operations a batch may carry as `sukiru-fileop <verb>
/// <path>…` commands (ADR-0007). None writes a ledger: they act only where no
/// official CLI can — an ownerless payload, a dead link, the link ↔ copy
/// mode of a host-folder placement, or a leftover host folder. The executor parses the argv back into
/// this type, so a malformed or unknown verb never runs.
public enum FileOperation: Equatable, Sendable {
    /// Delete an ownerless skill directory.
    case deleteDirectory(String)
    /// Delete a symlink (dangling or not); never follows it. Already absent
    /// counts as done, so a CLI removal earlier in the batch is harmless.
    case deleteLink(String)
    /// Replace a physical copy (or a link elsewhere) with a symlink to
    /// `target`.
    case relink(path: String, target: String)
    /// Replace a symlink with an independent copy of the directory it
    /// resolves to.
    case materialize(String)
    /// Delete a leftover host skills folder that holds only links, then its
    /// parent when nothing but Finder noise remains there.
    case removeLeftoverSkillsDir(String)

    static let executable = "sukiru-fileop"

    public init?(argv: [String]) {
        guard argv.first == Self.executable, argv.count >= 3 else {
            return nil
        }
        switch (argv[1], argv.count) {
        case ("delete-directory", 3):
            self = .deleteDirectory(argv[2])
        case ("delete-link", 3):
            self = .deleteLink(argv[2])
        case ("relink", 4):
            self = .relink(path: argv[2], target: argv[3])
        case ("materialize", 3):
            self = .materialize(argv[2])
        case ("remove-leftover-skills-dir", 3):
            self = .removeLeftoverSkillsDir(argv[2])
        default:
            return nil
        }
    }

    var argv: [String] {
        switch self {
        case .deleteDirectory(let path):
            return [Self.executable, "delete-directory", path]
        case .deleteLink(let path):
            return [Self.executable, "delete-link", path]
        case .relink(let path, let target):
            return [Self.executable, "relink", path, target]
        case .materialize(let path):
            return [Self.executable, "materialize", path]
        case .removeLeftoverSkillsDir(let path):
            return [Self.executable, "remove-leftover-skills-dir", path]
        }
    }

    /// Every path the operation reads or writes (workspace-boundary check).
    var paths: [String] {
        Array(argv.dropFirst(2))
    }

    func perform() throws {
        let fileManager = FileManager.default
        let probe = DefaultFileSystemProbe()
        switch self {
        case .deleteDirectory(let path):
            try fileManager.removeItem(atPath: path)
        case .deleteLink(let path):
            switch probe.entryKind(atPath: path) {
            case nil:
                return
            case .symlink?:
                try fileManager.removeItem(atPath: path)
            default:
                throw FileOperationError("'\(path)' is not a symlink; refusing to delete it")
            }
        case .relink(let path, let target):
            try Self.relink(path, to: target, probe: probe)
        case .materialize(let path):
            guard case .symlink? = probe.entryKind(atPath: path),
                let resolved = probe.resolvedPath(atPath: path),
                probe.isDirectory(atPath: resolved)
            else {
                throw FileOperationError("'\(path)' is not a link to a skill directory")
            }
            try Self.replace(path) {
                try fileManager.copyItem(atPath: resolved, toPath: path)
            }
        case .removeLeftoverSkillsDir(let path):
            try Self.removeLeftoverSkillsDir(path, probe: probe)
        }
    }

    /// Re-checks at run time that the folder still holds only links, so a
    /// copy added since the scan is never deleted. The parent goes too when
    /// it is left empty: an empty host config folder reads as an installed
    /// agent to host detection.
    private static func removeLeftoverSkillsDir(
        _ path: String, probe: DefaultFileSystemProbe
    ) throws {
        guard LeftoverHostRule.linkCount(in: path, fileSystem: probe) != nil else {
            throw FileOperationError("'\(path)' holds more than links; refusing to delete it")
        }
        let fileManager = FileManager.default
        try fileManager.removeItem(atPath: path)
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard parent != "/", parent != NSHomeDirectory(),
            let rest = probe.directoryEntries(atPath: parent),
            rest.allSatisfy(LeftoverHostRule.finderNoise.contains)
        else { return }
        try fileManager.removeItem(atPath: parent)
    }

    private static func relink(
        _ path: String, to target: String, probe: DefaultFileSystemProbe
    ) throws {
        switch probe.entryKind(atPath: path) {
        case .directory?, .symlink?:
            break
        default:
            throw FileOperationError("'\(path)' is neither a copy nor a link")
        }
        guard probe.isDirectory(atPath: target) else {
            throw FileOperationError("link target '\(target)' is not a directory")
        }
        try replace(path) {
            try FileManager.default.createSymbolicLink(
                atPath: path, withDestinationPath: target)
        }
    }

    /// Moves `path` aside, creates its replacement, then drops the original;
    /// a failed replacement puts the original back.
    private static func replace(_ path: String, with create: () throws -> Void) throws {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: path)
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).sukiru-\(UUID().uuidString)").path
        try fileManager.moveItem(atPath: path, toPath: aside)
        do {
            try create()
        } catch {
            try? fileManager.removeItem(atPath: path)
            try? fileManager.moveItem(atPath: aside, toPath: path)
            throw error
        }
        try fileManager.removeItem(atPath: aside)
    }
}

struct FileOperationError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
