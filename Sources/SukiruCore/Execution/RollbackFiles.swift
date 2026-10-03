import Foundation

public enum RollbackChoice: String, Codable, Sendable {
    case restore, preserve
}

public struct RollbackConflict: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case modified, deleted, added }
    public let path: String
    public let kind: Kind
    /// Unrelated later additions cannot be deleted by snapshot restoration.
    public let canRestore: Bool

    init(path: String, kind: Kind, canRestore: Bool = true) {
        self.path = path
        self.kind = kind
        self.canRestore = canRestore
    }
}

public struct RollbackPreview: Codable, Equatable, Sendable {
    public let batchID: String
    public let conflicts: [RollbackConflict]

    public func jsonData() throws -> Data {
        try deterministicJSONData(self)
    }
}

/// File identities never follow links. Inventories are execution evidence,
/// not an installation ledger; both sides belong to the snapshot.
struct RollbackFiles: Codable {
    struct Entry: Codable, Equatable {
        let kind: String
        let detail: String?
    }
    let roots: [String]
    let entries: [String: Entry]
    let containers: [String]

    static func roots(
        manifest: SnapshotManifest, affected: AffectedScope,
        environment: SukiruEnvironment
    ) -> [String] {
        let resolver = HostPathResolver(
            environment: environment, fileSystem: DefaultFileSystemProbe())
        var roots =
            manifest.ledgers.map(\.path) + manifest.payloads.map(\.path)
            + manifest.watchedDirectories + manifest.placements.map(\.path)
        if affected.workspaceIDs.contains("user") {
            roots.append(resolver.canonicalUserRoot())
            for host in HostTable.hosts {
                roots.append(resolver.globalSkillsRoot(for: host))
                roots += resolver.legacyGlobalSkillsRoots(for: host)
            }
        }
        for project in affected.roots {
            roots.append(resolver.canonicalProjectRoot(projectRoot: project))
            for host in HostTable.hosts {
                roots.append(resolver.projectSkillsRoot(for: host, projectRoot: project))
                roots += resolver.legacyProjectSkillsRoots(for: host, projectRoot: project)
            }
        }
        let all = Set(roots)
        return all.filter { path in
            !all.contains {
                path.hasPrefix($0 + "/")
                    && DefaultFileSystemProbe().entryKind(atPath: $0) == .directory
            }
        }.sorted()
    }

    static func capture(roots: [String]) throws -> RollbackFiles {
        var entries: [String: Entry] = [:]
        for root in roots { try collect(root, into: &entries) }
        var containers = Set<String>()
        for root in roots {
            var parent = URL(fileURLWithPath: root).deletingLastPathComponent().path
            while parent != "/" {
                if DefaultFileSystemProbe().entryKind(atPath: parent) == .directory {
                    containers.insert(parent)
                }
                parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
            }
        }
        return RollbackFiles(roots: roots, entries: entries, containers: containers.sorted())
    }

    private static func collect(_ path: String, into entries: inout [String: Entry]) throws {
        let manager = FileManager.default
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT || errno == ENOTDIR { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let attributes = try manager.attributesOfItem(atPath: path)
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory:
            entries[path] = Entry(kind: "directory", detail: nil)
            for child in try manager.contentsOfDirectory(atPath: path) {
                try collect(HostPathResolver.join(path, child), into: &entries)
            }
        case .typeSymbolicLink:
            entries[path] = Entry(
                kind: "link", detail: try manager.destinationOfSymbolicLink(atPath: path))
        case .typeRegular:
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            entries[path] = Entry(kind: "file", detail: SnapshotStore.sha256Hex(bytes))
        default:
            throw SnapshotError.captureFailed("unsupported file type at \(path)")
        }
    }

    func write(to directory: String, name: String) throws {
        try deterministicJSONData(self).write(
            to: URL(fileURLWithPath: HostPathResolver.join(directory, name)), options: .atomic)
    }

    static func load(from directory: String, name: String) throws -> RollbackFiles {
        let bytes = try Data(
            contentsOf: URL(fileURLWithPath: HostPathResolver.join(directory, name)))
        return try JSONDecoder().decode(Self.self, from: bytes)
    }

    func diff(to after: RollbackFiles) -> BatchDiff {
        let entries = conflicts(with: after).map { conflict in
            let kind: DiffEntry.Kind =
                conflict.kind == .added
                ? .fileAdded
                : conflict.kind == .deleted ? .fileRemoved : .fileChanged
            return DiffEntry(kind: kind, path: conflict.path, detail: "captured file state changed")
        }
        return BatchDiff(entries: entries, summary: Differ.summary(for: entries))
    }

    func conflicts(with current: RollbackFiles) -> [RollbackConflict] {
        Set(entries.keys).union(current.entries.keys).sorted().compactMap { path in
            guard entries[path] != current.entries[path] else { return nil }
            let kind: RollbackConflict.Kind =
                entries[path] == nil
                ? .added
                : current.entries[path] == nil ? .deleted : .modified
            return RollbackConflict(path: path, kind: kind)
        }
    }
}
