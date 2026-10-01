import Foundation

/// A placement enriched with the engine-side context the wire `Placement`
/// does not carry.
public struct DiscoveredPlacement: Equatable, Sendable {
    /// The skill name: parsed from `SKILL.md`, or the link's file name for a
    /// broken symlink (whose metadata is unreadable by definition).
    public let name: String
    /// The wire placement.
    public let placement: Placement
    /// The workspace this placement was found in.
    public let workspaceID: String
    /// The ownership/ambiguity bucket: `user` or `project:<root>`. Ownership
    /// is resolved per bucket, never across scopes.
    public let scopeGroup: String
    /// ALL hosts whose skills dir is this placement's workspace root, in
    /// host-table order — never a single host id. trae/trae-cn share
    /// `.trae/skills`; cline/dexto/warp/zed share the canonical store.
    public let candidateHosts: [String]
    /// Absolute path of the parsed `SKILL.md` (for broken symlinks: the path
    /// it WOULD have, `<link>/SKILL.md` — the file is unreadable by
    /// definition). Ownership evidence references this path.
    public let skillFilePath: String
    /// The gh-ledger claim from frontmatter, when present.
    public let githubProvenance: GitHubProvenance?

    public init(
        name: String,
        placement: Placement,
        workspaceID: String,
        scopeGroup: String,
        candidateHosts: [String],
        skillFilePath: String,
        githubProvenance: GitHubProvenance?
    ) {
        self.name = name
        self.placement = placement
        self.workspaceID = workspaceID
        self.scopeGroup = scopeGroup
        self.candidateHosts = candidateHosts
        self.skillFilePath = skillFilePath
        self.githubProvenance = githubProvenance
    }
}

/// The scanner's full output for a set of workspaces.
public struct InventoryResult: Equatable, Sendable {
    /// Every discovered placement, sorted by (path, workspaceID) — the
    /// tiebreak matters because overlapping roots can yield equal paths.
    public let placements: [DiscoveredPlacement]
    /// Non-fatal problems, sorted by (path, kind, message).
    public let issues: [Issue]
    /// Findings raised during discovery (broken symlinks), sorted by
    /// (ruleID, workspaceID, skillName).
    public let findings: [Finding]

    public init(placements: [DiscoveredPlacement], issues: [Issue], findings: [Finding]) {
        self.placements = placements
        self.issues = issues
        self.findings = findings
    }
}

/// Recursive placement discovery per workspace root.
///
/// The port is faithful on the load-bearing semantics:
///
/// - Children are lstat'd and iterated in sorted (lexicographic) order — the
///   sole source of scan determinism.
/// - A symlink is stat-FOLLOWED once: resolves to a skill dir → `symlink`
///   placement with the raw `linkTarget` and a fully resolved `canonicalPath`
///   (realpath(3)); resolves to anything else → silently skipped (no descent
///   through symlinks, so cycles cannot hang the scan); dangling → a
///   first-class `brokenSymlink` placement named after the link file, plus an
///   issue and a `broken-symlink` finding. Broken links are never skipped.
/// - Ignored containers (`ContainerIgnoreList`) are skipped even when they
///   carry a valid-looking `SKILL.md`.
/// - A directory containing `SKILL.md` IS a skill; the scanner never descends
///   into it.
/// - Frontmatter parse failures (`skill-md-invalid` / `skill-md-unreadable`)
///   flow into the issue stream per placement; the dir yields no placement.
/// - Unreadable directories and uninspectable entries become issues; the
///   scan always completes.
/// - An absent workspace root is silent (a configured-but-absent host is not
///   an issue); a root that exists but is not a usable directory is an issue.
public struct InventoryScanner: Sendable {
    private let fileSystem: FileSystemProbe
    private let parser: FrontmatterParser
    private let hasher: ContentHasher

    public init(fileSystem: FileSystemProbe = DefaultFileSystemProbe()) {
        self.fileSystem = fileSystem
        self.parser = FrontmatterParser(fileSystem: fileSystem)
        self.hasher = ContentHasher(fileSystem: fileSystem)
    }

    /// Mutable accumulators threaded through the recursion.
    private struct Outcome {
        var placements: [DiscoveredPlacement] = []
        var issues: [Issue] = []
        var findings: [Finding] = []
    }

    /// Scans every workspace once (duplicate roots collapse onto the first
    /// occurrence) and returns the sorted, deterministic result.
    public func scan(workspaces: [EnumeratedWorkspace]) -> InventoryResult {
        var outcome = Outcome()
        var seenRoots: Set<String> = []
        for workspace in workspaces where seenRoots.insert(workspace.workspace.root).inserted {
            scanWorkspace(workspace, into: &outcome)
        }
        // Swift's sort is NOT stable: overlapping workspace roots (a nested
        // root, or a host dir inside another workspace's tree) can discover
        // the same placement path twice, so path alone is not a total order.
        // workspaceID breaks the tie, keeping output byte-deterministic.
        outcome.placements.sort {
            ($0.placement.path, $0.workspaceID) < ($1.placement.path, $1.workspaceID)
        }
        outcome.issues.sort { ($0.path, $0.kind, $0.message) < ($1.path, $1.kind, $1.message) }
        outcome.findings.sort {
            ($0.ruleID, $0.workspaceID, $0.skillName ?? "")
                < ($1.ruleID, $1.workspaceID, $1.skillName ?? "")
        }
        return InventoryResult(
            placements: outcome.placements,
            issues: outcome.issues,
            findings: outcome.findings
        )
    }

    // MARK: - Workspace roots

    private func scanWorkspace(_ workspace: EnumeratedWorkspace, into outcome: inout Outcome) {
        let root = workspace.workspace.root
        guard let kind = fileSystem.entryKind(atPath: root) else {
            // NotFound: a configured-but-absent host is not an issue.
            return
        }
        switch kind {
        case .directory:
            break
        case .symlink:
            // A symlinked root must stat-resolve to a directory, otherwise the
            // workspace is skipped with an issue (never fatal).
            guard fileSystem.isDirectory(atPath: root) else {
                outcome.issues.append(
                    Issue(
                        kind: IssueKind.directoryUnreadable,
                        path: root,
                        message: "workspace root symlink does not resolve to a directory"))
                return
            }
        case .file, .other:
            outcome.issues.append(
                Issue(
                    kind: IssueKind.directoryUnreadable,
                    path: root,
                    message: "workspace root is not a directory"))
            return
        }
        scanContainer(root, workspace: workspace, into: &outcome)
    }

    // MARK: - Recursion

    private func scanContainer(
        _ container: String, workspace: EnumeratedWorkspace, into outcome: inout Outcome
    ) {
        if fileSystem.isFile(atPath: HostPathResolver.join(container, "SKILL.md")) {
            inspectPlacement(at: container, linkTarget: nil, workspace: workspace, into: &outcome)
            return
        }
        guard let children = fileSystem.directoryEntries(atPath: container) else {
            outcome.issues.append(
                Issue(
                    kind: IssueKind.directoryUnreadable,
                    path: container,
                    message: "directory could not be read"))
            return
        }
        // Lexicographic child order is the sole source of scan determinism.
        for name in children.sorted() {
            let child = HostPathResolver.join(container, name)
            guard let kind = fileSystem.entryKind(atPath: child) else {
                outcome.issues.append(
                    Issue(
                        kind: IssueKind.directoryUnreadable,
                        path: child,
                        message: "directory entry could not be inspected"))
                continue
            }
            switch kind {
            case .symlink(let target):
                if !fileSystem.exists(atPath: child) {
                    recordBrokenSymlink(
                        at: child, name: name, target: target,
                        workspace: workspace, into: &outcome)
                    continue
                }
                let resolvesToSkillDir =
                    fileSystem.isDirectory(atPath: child)
                    && fileSystem.isFile(atPath: HostPathResolver.join(child, "SKILL.md"))
                if resolvesToSkillDir {
                    inspectPlacement(
                        at: child, linkTarget: target, workspace: workspace, into: &outcome)
                }
            // Otherwise (resolves to a non-skill dir or a file): silently
            // skipped. Symlinks are never recursed into, so cycles
            // cannot hang the scan.
            case .directory:
                guard !ContainerIgnoreList.isIgnored(name: name) else { continue }
                scanContainer(child, workspace: workspace, into: &outcome)
            case .file, .other:
                continue
            }
        }
    }

    // MARK: - Placements

    private func inspectPlacement(
        at path: String,
        linkTarget: String?,
        workspace: EnumeratedWorkspace,
        into outcome: inout Outcome
    ) {
        let skillFile = HostPathResolver.join(path, "SKILL.md")
        let metadata: SkillMetadata
        switch parser.parse(skillFileAt: skillFile) {
        case .failure(let issue):
            // skill-md-invalid / skill-md-unreadable flow into the issue
            // stream; the directory yields no placement.
            outcome.issues.append(issue)
            return
        case .success(let parsed):
            metadata = parsed
        }
        let canonicalPath = fileSystem.resolvedPath(atPath: path)
        if canonicalPath == nil {
            outcome.issues.append(
                Issue(
                    kind: IssueKind.canonicalPathUnreadable,
                    path: path,
                    message: "path could not be fully resolved"))
        }
        var contentHash: String?
        switch hasher.computedHash(ofSkillAtPath: path) {
        case .success(let hash):
            contentHash = hash
        case .failure(let issue):
            outcome.issues.append(issue)
        }
        outcome.placements.append(
            DiscoveredPlacement(
                name: metadata.name,
                placement: Placement(
                    path: path,
                    kind: linkTarget == nil ? .directory : .symlink,
                    linkTarget: linkTarget,
                    canonicalPath: canonicalPath,
                    contentHash: contentHash,
                    internal: metadata.internal,
                    managingAgent: linkTarget == nil
                        ? AgentManagedDirectories(fileSystem: fileSystem).managingAgent(
                            ofDirectory: path, in: workspace) : nil
                ),
                workspaceID: workspace.workspace.id,
                scopeGroup: workspace.scopeGroup,
                candidateHosts: workspace.candidateHosts,
                skillFilePath: metadata.skillFilePath,
                githubProvenance: metadata.githubProvenance
            ))
    }

    /// Dangling links are first-class placements (visible and cleanable),
    /// named after the link file because the target's metadata is gone. An
    /// issue AND a `broken-symlink` finding ride alongside.
    private func recordBrokenSymlink(
        at path: String,
        name: String,
        target: String,
        workspace: EnumeratedWorkspace,
        into outcome: inout Outcome
    ) {
        outcome.placements.append(
            DiscoveredPlacement(
                name: name,
                placement: Placement(
                    path: path,
                    kind: .brokenSymlink,
                    linkTarget: target,
                    canonicalPath: nil,
                    contentHash: nil,
                    internal: false,
                    managingAgent: nil
                ),
                workspaceID: workspace.workspace.id,
                scopeGroup: workspace.scopeGroup,
                candidateHosts: workspace.candidateHosts,
                skillFilePath: HostPathResolver.join(path, "SKILL.md"),
                githubProvenance: nil
            ))
        outcome.issues.append(
            Issue(
                kind: IssueKind.brokenSymlink,
                path: path,
                message: "broken symlink → \(target)"))
        outcome.findings.append(
            Finding(
                ruleID: "broken-symlink",
                severity: .action,
                skillName: name,
                workspaceID: workspace.workspace.id,
                evidence: linkEvidence(linkPath: path, linkTarget: target)
            ))
    }

    private func linkEvidence(linkPath: String, linkTarget: String) -> [Evidence] {
        // Single-line literal: the two lint gates disagree on trailing commas
        // in multi-line collection literals.
        let link = Evidence(kind: "linkPath", detail: linkPath)
        let target = Evidence(kind: "linkTarget", detail: linkTarget)
        return [link, target]
    }
}
