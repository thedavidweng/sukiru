import Foundation

/// One agent host's directory + detection specification.
///
/// Ported verbatim from `research/host-table.json`, which mirrors the agent
/// definitions of the pinned `skills` CLI (see its `upstreamPin`). The static
/// data lives in the generated `HostTableData.swift`; a unit test asserts
/// parity with the JSON. Field semantics:
///
/// - `projectSkillDir` is relative to a project root.
/// - `globalSkillDirRelative` is relative to the RESOLVED base (see
///   `HostSpec.GlobalBase`), never to `$HOME` directly.
/// - `detectionMarker` is an existence probe; the empty string means "probe the
///   resolved config home itself and never fall through to `$HOME`".
/// - `extraMarkers` are probed against `$HOME` only.
/// - `legacyProjectSkillDirs` / `legacyGlobalSkillDirs` are dirs the pinned
///   CLI no longer installs into but users may still hold, relative like
///   `projectSkillDir` / `globalSkillDirRelative`. They are scanned
///   read-only and are never an install target.
/// - `ghAgentId` is the `gh skill install --agent` value for the host, which
///   can differ from `id` (the `npx skills -a` value); nil when gh does not
///   accept the host.
public struct HostSpec: Equatable, Sendable, Codable {
    /// How a host's global configuration base directory is resolved.
    public enum GlobalBase: String, Equatable, Sendable, Codable {
        /// `$HOME` (fallback `$USERPROFILE`).
        case home = "Home"
        /// `$XDG_CONFIG_HOME` if set and non-empty, else `$HOME/.config`.
        case xdg = "Xdg"
        /// `$<envHomeVar>` if set and non-empty, else `$HOME/<envFallbackDir>`.
        case env = "Env"
    }

    public let id: String
    public let displayName: String
    public let projectSkillDir: String
    public let globalSkillDirRelative: String
    public let detectionMarker: String
    public let envHomeVar: String?
    public let envFallbackDir: String?
    public let extraMarkers: [String]
    public let globalBase: GlobalBase
    public let detectInProject: Bool
    public let showInUniversalList: Bool
    public let legacyProjectSkillDirs: [String]
    public let legacyGlobalSkillDirs: [String]
    public let ghAgentId: String?

    public init(
        id: String,
        displayName: String,
        projectSkillDir: String,
        globalSkillDirRelative: String,
        detectionMarker: String,
        envHomeVar: String?,
        envFallbackDir: String?,
        extraMarkers: [String],
        globalBase: GlobalBase,
        detectInProject: Bool,
        showInUniversalList: Bool,
        legacyProjectSkillDirs: [String],
        legacyGlobalSkillDirs: [String],
        ghAgentId: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.projectSkillDir = projectSkillDir
        self.globalSkillDirRelative = globalSkillDirRelative
        self.detectionMarker = detectionMarker
        self.envHomeVar = envHomeVar
        self.envFallbackDir = envFallbackDir
        self.extraMarkers = extraMarkers
        self.globalBase = globalBase
        self.detectInProject = detectInProject
        self.showInUniversalList = showInUniversalList
        self.legacyProjectSkillDirs = legacyProjectSkillDirs
        self.legacyGlobalSkillDirs = legacyGlobalSkillDirs
        self.ghAgentId = ghAgentId
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case projectSkillDir
        case globalSkillDirRelative
        case detectionMarker
        case envHomeVar
        case envFallbackDir
        case extraMarkers
        case globalBase
        case detectInProject
        case showInUniversalList
        case legacyProjectSkillDirs
        case legacyGlobalSkillDirs
        case ghAgentId
    }
}

/// Per-host installation state (a tri-state).
///
/// The official CLI sprays symlinks into every known agent layout regardless of
/// what is actually installed, so plain directory existence is not evidence of
/// installation. `marks_installation` distinguishes a real install from CLI
/// spray residue.
public enum HostDetectionState: String, Equatable, Sendable, Codable {
    /// The host's config base marks an installation.
    case detected
    /// The global skills root exists but the host is not detected: CLI spray
    /// residue. Still scannable, but flagged `installed = false`.
    case leftover
    /// Neither detected nor a residual skills root on disk.
    case absent
}
