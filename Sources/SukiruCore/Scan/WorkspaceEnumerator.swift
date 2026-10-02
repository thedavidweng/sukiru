/// Builds the workspace root set for a scan.
///
/// User scope: the canonical `~/.agents/skills` store plus every detected or
/// leftover host global dir. Leftover roots (CLI spray residue) stay in the
/// scan set but are flagged `installed = false`; absent hosts are omitted.
///
/// Project scope: for each registered project root, the canonical
/// `.agents/skills` store plus one workspace per host project dir. Project
/// host detection is intentionally permissive: a plain
/// existence test on the skills dir OR the detection marker, never
/// `marks_installation`. Hosts sharing a project dir (trae/trae-cn share
/// `.trae/skills`) collapse to one workspace per path; the first host in
/// table order lends its id.
///
/// Legacy dirs (`legacyGlobalSkillDirs` / `legacyProjectSkillDirs`) are
/// scanned read-only when they exist on disk, as `…#legacy:<dir>`
/// workspaces after the host workspaces of their scope.
///
/// The output order is defined and deterministic: user scope first (canonical
/// then hosts in host-table order), then project scopes sorted by root.
/// A workspace enriched with the engine-side context the wire
/// `Workspace` does not carry.
public struct EnumeratedWorkspace: Equatable, Sendable {
    /// The wire workspace.
    public let workspace: Workspace
    /// ALL hosts whose resolved skills dir IS this workspace's root, in
    /// host-table order — never a single host id
    /// (trae/trae-cn share project dir `.trae/skills`; cline/dexto/warp/zed
    /// share the canonical store).
    public let candidateHosts: [String]
    /// The ownership/ambiguity bucket: `user` for user scope, `project:<root>`
    /// per project root.
    public let scopeGroup: String

    public init(workspace: Workspace, candidateHosts: [String], scopeGroup: String) {
        self.workspace = workspace
        self.candidateHosts = candidateHosts
        self.scopeGroup = scopeGroup
    }
}

public struct WorkspaceEnumerator: Sendable {
    /// Separates a host workspace id from the legacy dir it was found at.
    public static let legacyIDMarker = "#legacy:"

    /// Whether a workspace id names a legacy dir: one the CLI no longer
    /// installs into, so no command may target it through a host.
    public static func isLegacy(workspaceID: String) -> Bool {
        workspaceID.contains(legacyIDMarker)
    }

    private let environment: SukiruEnvironment
    private let fileSystem: FileSystemProbe
    private let resolver: HostPathResolver
    private let detector: HostDetector

    public init(environment: SukiruEnvironment, fileSystem: FileSystemProbe) {
        self.environment = environment
        self.fileSystem = fileSystem
        self.resolver = HostPathResolver(environment: environment, fileSystem: fileSystem)
        self.detector = HostDetector(environment: environment, fileSystem: fileSystem)
    }

    /// All workspaces in both scopes, in defined order. `projectRoots` is the
    /// already-resolved root set (root precedence is the caller's job).
    public func enumerate(projectRoots: [String]) -> [Workspace] {
        enumerateDetailed(projectRoots: projectRoots).map(\.workspace)
    }

    /// `enumerate` plus per-workspace candidate host sets and scope groups
    /// for the inventory scanner.
    public func enumerateDetailed(projectRoots: [String]) -> [EnumeratedWorkspace] {
        var workspaces = enumerateUserScope()
        for root in projectRoots.sorted() {
            workspaces.append(contentsOf: enumerateProjectScope(projectRoot: root))
        }
        return workspaces
    }

    private func enumerateUserScope() -> [EnumeratedWorkspace] {
        let canonical = resolver.canonicalUserRoot()
        var workspaces = [
            EnumeratedWorkspace(
                workspace: Workspace(id: "user", kind: .user, root: canonical, installed: true),
                candidateHosts: userCandidates(root: canonical),
                scopeGroup: "user"
            )
        ]
        // Dedup by resolved root, mirroring the project-scope seen set: hosts
        // sharing one global dir (amp/replit/universal →
        // `~/.config/agents/skills`; zencoder/zenflow → `~/.zencoder/skills`;
        // cline/warp/dexto → the canonical store)
        // emit ONE workspace. The first non-absent host in table order lends
        // its id; every sharing host stays visible via candidateHosts.
        var seen: Set<String> = [canonical]
        for host in HostTable.hosts {
            let state = detector.detectionState(for: host)
            guard state != .absent else { continue }
            let root = resolver.globalSkillsRoot(for: host)
            guard !seen.contains(root) else { continue }
            seen.insert(root)
            // `installed` reflects EVERY host sharing the root, not just the
            // id-lending first sharer: the first sharer may be spray residue
            // while a later one is really installed.
            let sharers = HostTable.hosts.filter { resolver.globalSkillsRoot(for: $0) == root }
            let installed = sharers.contains { detector.detectionState(for: $0) == .detected }
            workspaces.append(
                EnumeratedWorkspace(
                    workspace: Workspace(
                        id: "host:\(host.id)",
                        kind: .user,
                        root: root,
                        installed: installed
                    ),
                    candidateHosts: sharers.map(\.id),
                    scopeGroup: "user"
                )
            )
        }
        workspaces += legacyUserWorkspaces(seen: &seen)
        return workspaces
    }

    private func enumerateProjectScope(projectRoot: String) -> [EnumeratedWorkspace] {
        let canonical = resolver.canonicalProjectRoot(projectRoot: projectRoot)
        var workspaces = [
            EnumeratedWorkspace(
                workspace: Workspace(
                    id: "project:\(projectRoot)",
                    kind: .project,
                    root: canonical,
                    installed: true
                ),
                candidateHosts: projectCandidates(root: canonical, projectRoot: projectRoot),
                scopeGroup: "project:\(projectRoot)"
            )
        ]
        var seen: Set<String> = [canonical]
        for host in HostTable.hosts {
            let root = resolver.projectSkillsRoot(for: host, projectRoot: projectRoot)
            guard !seen.contains(root) else { continue }
            let dirExists = fileSystem.exists(atPath: root)
            // ARCHIVE DIVERGENCE (deliberate):
            // the archive probes `project_root.join(detection_marker).exists()`
            // UNGUARDED, and `Path::join("")` is the root itself — so the
            // archive registered a phantom project workspace for every
            // empty-marker host (claude-code/codex/mistral-vibe) in EVERY
            // extant project root. The `!isEmpty` guard keeps the workspace
            // set honest.
            let markerExists =
                !host.detectionMarker.isEmpty
                && fileSystem.exists(
                    atPath: HostPathResolver.join(projectRoot, host.detectionMarker)
                )
            guard dirExists || markerExists else { continue }
            seen.insert(root)
            workspaces.append(
                EnumeratedWorkspace(
                    workspace: Workspace(
                        id: "project:\(projectRoot)#\(host.id)",
                        kind: .project,
                        root: root,
                        installed: true
                    ),
                    candidateHosts: projectCandidates(root: root, projectRoot: projectRoot),
                    scopeGroup: "project:\(projectRoot)"
                )
            )
        }
        workspaces += legacyProjectWorkspaces(projectRoot: projectRoot, seen: &seen)
        return workspaces
    }

    /// User-scope workspaces for legacy global dirs present on disk.
    /// `installed` reflects detection of any host listing the dir.
    private func legacyUserWorkspaces(seen: inout Set<String>) -> [EnumeratedWorkspace] {
        var workspaces: [EnumeratedWorkspace] = []
        for host in HostTable.hosts {
            let roots = resolver.legacyGlobalSkillsRoots(for: host)
            for (dir, root) in zip(host.legacyGlobalSkillDirs, roots)
            where !seen.contains(root) && fileSystem.exists(atPath: root) {
                seen.insert(root)
                let sharers = HostTable.hosts.filter {
                    resolver.legacyGlobalSkillsRoots(for: $0).contains(root)
                }
                workspaces.append(
                    EnumeratedWorkspace(
                        workspace: Workspace(
                            id: "host:\(host.id)\(Self.legacyIDMarker)\(dir)",
                            kind: .user,
                            root: root,
                            installed: sharers.contains(where: detector.isDetected)
                        ),
                        candidateHosts: sharers.map(\.id),
                        scopeGroup: "user"
                    )
                )
            }
        }
        return workspaces
    }

    /// Project-scope workspaces for legacy project dirs present on disk.
    private func legacyProjectWorkspaces(
        projectRoot: String, seen: inout Set<String>
    ) -> [EnumeratedWorkspace] {
        var workspaces: [EnumeratedWorkspace] = []
        for host in HostTable.hosts {
            let roots = resolver.legacyProjectSkillsRoots(for: host, projectRoot: projectRoot)
            for (dir, root) in zip(host.legacyProjectSkillDirs, roots)
            where !seen.contains(root) && fileSystem.exists(atPath: root) {
                seen.insert(root)
                let sharers = HostTable.hosts.filter {
                    resolver.legacyProjectSkillsRoots(for: $0, projectRoot: projectRoot)
                        .contains(root)
                }
                workspaces.append(
                    EnumeratedWorkspace(
                        workspace: Workspace(
                            id: "project:\(projectRoot)#\(host.id)\(Self.legacyIDMarker)\(dir)",
                            kind: .project,
                            root: root,
                            installed: true
                        ),
                        candidateHosts: sharers.map(\.id),
                        scopeGroup: "project:\(projectRoot)"
                    )
                )
            }
        }
        return workspaces
    }

    /// Every host whose resolved GLOBAL skills dir equals `root`, in
    /// host-table order (path sharing is a physical fact, independent of
    /// detection state).
    private func userCandidates(root: String) -> [String] {
        HostTable.hosts.filter { resolver.globalSkillsRoot(for: $0) == root }.map(\.id)
    }

    /// Every host whose resolved PROJECT skills dir equals `root`, in
    /// host-table order.
    private func projectCandidates(root: String, projectRoot: String) -> [String] {
        HostTable.hosts.filter {
            resolver.projectSkillsRoot(for: $0, projectRoot: projectRoot) == root
        }.map(\.id)
    }
}
