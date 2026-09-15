/// Builds the workspace root set for a scan (architecture §4.1,
/// port-reference §3).
///
/// User scope: the canonical `~/.agents/skills` store plus every detected or
/// leftover host global dir. Leftover roots (CLI spray residue) stay in the
/// scan set but are flagged `installed = false`; absent hosts are omitted.
///
/// Project scope: for each registered project root, the canonical
/// `.agents/skills` store plus one workspace per host project dir. Project
/// host detection is intentionally permissive (port-reference §2): a plain
/// existence test on the skills dir OR the detection marker, never
/// `marks_installation`. Hosts sharing a project dir (trae/trae-cn share
/// `.trae/skills`) collapse to one workspace per path; the first host in
/// table order lends its id.
///
/// The output order is defined and deterministic: user scope first (canonical
/// then hosts in host-table order), then project scopes sorted by root.
/// A workspace enriched with the engine-side context the D18 wire
/// `Workspace` does not carry.
public struct EnumeratedWorkspace: Equatable, Sendable {
    /// The D18 wire workspace.
    public let workspace: Workspace
    /// ALL hosts whose resolved skills dir IS this workspace's root, in
    /// host-table order — never a single host id (port-reference trap 12:
    /// trae/trae-cn share project dir `.trae/skills`; cline/dexto/warp/zed
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
    /// already-resolved root set (D5 precedence is the caller's job).
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
        for host in HostTable.hosts {
            let state = detector.detectionState(for: host)
            guard state != .absent else { continue }
            let root = resolver.globalSkillsRoot(for: host)
            // Hosts whose global dir IS the canonical store (cline, warp,
            // dexto) are covered by the `user` workspace.
            guard root != canonical else { continue }
            workspaces.append(
                EnumeratedWorkspace(
                    workspace: Workspace(
                        id: "host:\(host.id)",
                        kind: .user,
                        root: root,
                        installed: state == .detected
                    ),
                    candidateHosts: userCandidates(root: root),
                    scopeGroup: "user"
                )
            )
        }
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
