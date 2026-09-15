import Foundation

/// Relationship between a lock file's schema version and the supported one
/// (port-reference §6, trap #5: the archive silently accepted NEWER versions;
/// Sukiru surfaces them).
public enum LockVersionStatus: Equatable, Sendable {
    /// Version matches the supported schema.
    case supported
    /// Version is below supported: entries must NOT be used.
    case incompatible(found: Int, supported: Int)
    /// Version is above supported: surfaced, entries parsed best-effort.
    case newerThanSupported(found: Int, supported: Int)
}

/// One entry in a Vercel lock's `skills` map (architecture §4.1,
/// port-reference §6 `SkillLockEntry`).
///
/// All fields are optional and decoded tolerantly — a missing or mistyped
/// known field reads as nil rather than failing the whole file. Keys outside
/// the known schema are preserved verbatim in `extras`, never dropped.
public struct VercelLockEntry: Equatable, Sendable {
    public let source: String?
    public let sourceType: String?
    public let sourceUrl: String?
    public let ref: String?
    public let skillPath: String?
    /// Project-scope content hash (recomputable; drift detection applies).
    public let computedHash: String?
    /// Global-scope git tree SHA (passthrough display only, never recomputed).
    public let skillFolderHash: String?
    public let installedAt: String?
    public let updatedAt: String?
    public let pluginName: String?
    public let sourceBaseUrl: String?
    public let wellKnownDigest: String?
    /// Unknown entry-level keys, preserved verbatim.
    public let extras: [String: JSONValue]

    /// Keys consumed by the known schema; everything else lands in `extras`.
    /// Space-listed to avoid a multi-line collection literal (repo lint gates
    /// conflict on those).
    public static let knownKeys: Set<String> = {
        let identity = "source sourceType sourceUrl ref skillPath".split(separator: " ")
        let hashes = "skillFolderHash computedHash".split(separator: " ")
        let rest = "installedAt updatedAt pluginName sourceBaseUrl wellKnownDigest".split(
            separator: " ")
        return Set((identity + hashes + rest).map(String.init))
    }()

    public init(object: [String: JSONValue]) {
        source = object["source"]?.stringValue
        sourceType = object["sourceType"]?.stringValue
        sourceUrl = object["sourceUrl"]?.stringValue
        ref = object["ref"]?.stringValue
        skillPath = object["skillPath"]?.stringValue
        computedHash = object["computedHash"]?.stringValue
        skillFolderHash = object["skillFolderHash"]?.stringValue
        installedAt = object["installedAt"]?.stringValue
        updatedAt = object["updatedAt"]?.stringValue
        pluginName = object["pluginName"]?.stringValue
        sourceBaseUrl = object["sourceBaseUrl"]?.stringValue
        wellKnownDigest = object["wellKnownDigest"]?.stringValue
        var extras: [String: JSONValue] = [:]
        for (key, value) in object where !Self.knownKeys.contains(key) {
            extras[key] = value
        }
        self.extras = extras
    }

    /// Upstream `managed()`: both identity fields present and non-empty.
    public var isManaged: Bool {
        guard let source, let sourceType else { return false }
        return !source.isEmpty && !sourceType.isEmpty
    }

    /// Upstream `source_identity()`: `source|sourceType|skillPath|ref`.
    public var sourceIdentity: String {
        [source ?? "", sourceType ?? "", skillPath ?? "", ref ?? ""].joined(separator: "|")
    }
}

/// A parsed Vercel lock file (project v1 or global v3).
public struct VercelLock: Equatable, Sendable {
    /// Which lock schema this is (upstream `LockScope`).
    public enum Scope: String, Equatable, Sendable {
        case global
        case project

        /// Upstream `expected_version()`.
        public var expectedVersion: Int {
            switch self {
            case .global:
                return VercelLockReader.globalLockVersion
            case .project:
                return VercelLockReader.projectLockVersion
            }
        }
    }

    public let scope: Scope
    public let version: Int
    public let versionStatus: LockVersionStatus
    /// Entries keyed by bare skill name.
    public let entries: [String: VercelLockEntry]
    /// The `dismissed` prompt state, preserved as a raw tree.
    public let dismissed: JSONValue?
    public let lastSelectedAgents: [String]?
    /// Unknown top-level keys, preserved verbatim.
    public let extras: [String: JSONValue]

    /// Known top-level keys; everything else lands in `extras`.
    public static let knownKeys: Set<String> = Set(
        "version skills dismissed lastSelectedAgents".split(separator: " ").map(String.init)
    )

    /// An empty lock at the scope's expected version (missing file case).
    public static func empty(scope: Scope) -> VercelLock {
        VercelLock(
            scope: scope,
            version: scope.expectedVersion,
            versionStatus: .supported,
            entries: [:],
            dismissed: nil,
            lastSelectedAgents: nil,
            extras: [:]
        )
    }
}

/// The outcome of reading one lock file: the resolved path (nil when no
/// project probe candidate exists), the parsed lock (nil when unreadable or
/// incompatible), and a non-fatal issue when the file was problematic.
public struct LockReadResult: Equatable, Sendable {
    public let path: String?
    public let lock: VercelLock?
    public let issue: Issue?

    public init(path: String?, lock: VercelLock?, issue: Issue?) {
        self.path = path
        self.lock = lock
        self.issue = issue
    }
}

/// Reads Vercel `skills` lock files (architecture §4.1, port-reference §6).
///
/// Project lock (v1) probe order, first existing wins and files are NEVER
/// merged: `skills-lock.json` → `.agents/.skill-lock.json` → `.skill-lock.json`.
///
/// Global lock (v3): `$XDG_STATE_HOME/skills/.skill-lock.json` when the
/// variable is set AND non-empty — the archive's empty-string bug (a relative
/// path resolved against the CWD) is fixed here, not reproduced — else
/// `<home>/.agents/.skill-lock.json`. All environment reads flow through the
/// `SukiruEnvironment` seam, so a `SUKIRU_HOME` override keeps scans hermetic.
///
/// Missing file = empty lock. Malformed JSON = `ledger-unreadable` issue.
/// Older version = `lock-version-unsupported` issue, entries not used. Newer
/// version = `lock-version-unsupported` issue AND best-effort parse.
public struct VercelLockReader: Sendable {
    public static let globalLockVersion = 3
    public static let projectLockVersion = 1

    /// Project probe order (architecture §4.1). Space-listed to avoid a
    /// multi-line collection literal (repo lint gates conflict on those).
    public static let projectProbeOrder: [String] =
        "skills-lock.json .agents/.skill-lock.json .skill-lock.json"
        .split(separator: " ").map(String.init)

    private let environment: SukiruEnvironment
    private let fileSystem: FileSystemProbe

    public init(
        environment: SukiruEnvironment,
        fileSystem: FileSystemProbe = DefaultFileSystemProbe()
    ) {
        self.environment = environment
        self.fileSystem = fileSystem
    }

    /// The resolved global lock path (never nil; the file itself may not
    /// exist). The SUKIRU override wins, then the real `XDG_STATE_HOME`
    /// (suppressed under a `SUKIRU_HOME` override), then `$HOME/.agents`.
    public func globalLockPath() -> String {
        if let xdg = environment.xdgStateHome ?? environment.externalValue(for: "XDG_STATE_HOME") {
            return HostPathResolver.join(xdg, "skills/.skill-lock.json")
        }
        return HostPathResolver.join(environment.home, ".agents/.skill-lock.json")
    }

    /// The first existing project lock probe candidate, or nil when none
    /// exists. The probe is existence-only; an unreadable hit is reported as
    /// an issue rather than skipped to the next candidate.
    public func projectLockPath(projectRoot: String) -> String? {
        for candidate in Self.projectProbeOrder {
            let path = HostPathResolver.join(projectRoot, candidate)
            if fileSystem.exists(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Reads the global (v3) lock.
    public func readGlobalLock() -> LockReadResult {
        readLock(at: globalLockPath(), scope: .global)
    }

    /// Reads the project (v1) lock for a project root, or returns an empty
    /// lock when no probe candidate exists.
    public func readProjectLock(projectRoot: String) -> LockReadResult {
        guard let path = projectLockPath(projectRoot: projectRoot) else {
            return LockReadResult(path: nil, lock: .empty(scope: .project), issue: nil)
        }
        return readLock(at: path, scope: .project)
    }

    private func readLock(at path: String, scope: VercelLock.Scope) -> LockReadResult {
        guard let data = fileSystem.fileContents(atPath: path) else {
            if fileSystem.exists(atPath: path) {
                // Exists but unreadable (e.g. a directory at the lock path):
                // an issue, mirroring upstream's io error — never "missing".
                return LockReadResult(path: path, lock: nil, issue: unreadable(path))
            }
            // Missing file = empty lock.
            return LockReadResult(path: path, lock: .empty(scope: scope), issue: nil)
        }
        guard let lock = Self.decode(data, scope: scope) else {
            return LockReadResult(path: path, lock: nil, issue: unreadable(path))
        }
        switch lock.versionStatus {
        case .supported:
            return LockReadResult(path: path, lock: lock, issue: nil)
        case .incompatible(let found, let supported):
            let message =
                "lock version \(found) is older than supported version "
                + "\(supported); entries not used"
            return LockReadResult(
                path: path,
                lock: nil,
                issue: Issue(kind: IssueKind.lockVersionUnsupported, path: path, message: message)
            )
        case .newerThanSupported(let found, let supported):
            let message =
                "lock version \(found) is newer than supported version "
                + "\(supported); parsed best-effort"
            return LockReadResult(
                path: path,
                lock: lock,
                issue: Issue(kind: IssueKind.lockVersionUnsupported, path: path, message: message)
            )
        }
    }

    /// Best-effort decode of a lock file body. Returns nil when the JSON is
    /// malformed or the known schema shape (`version` int, `skills` object) is
    /// violated; individual non-object entries are skipped, not fatal.
    static func decode(_ data: Data, scope: VercelLock.Scope) -> VercelLock? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
            case .object(let object) = root,
            let version = object["version"]?.intValue,
            case .object(let skills)? = object["skills"]
        else {
            return nil
        }
        var entries: [String: VercelLockEntry] = [:]
        for (name, value) in skills {
            guard case .object(let entryObject) = value else { continue }
            entries[name] = VercelLockEntry(object: entryObject)
        }
        let expected = scope.expectedVersion
        let status: LockVersionStatus
        if version < expected {
            status = .incompatible(found: version, supported: expected)
        } else if version > expected {
            status = .newerThanSupported(found: version, supported: expected)
        } else {
            status = .supported
        }
        var extras: [String: JSONValue] = [:]
        for (key, value) in object where !VercelLock.knownKeys.contains(key) {
            extras[key] = value
        }
        return VercelLock(
            scope: scope,
            version: version,
            versionStatus: status,
            entries: entries,
            dismissed: object["dismissed"],
            lastSelectedAgents: object["lastSelectedAgents"]?.arrayValue?.compactMap(\.stringValue),
            extras: extras
        )
    }

    private func unreadable(_ path: String) -> Issue {
        Issue(
            kind: IssueKind.ledgerUnreadable,
            path: path,
            message: "lock file could not be parsed as a valid v-lock JSON document"
        )
    }
}
