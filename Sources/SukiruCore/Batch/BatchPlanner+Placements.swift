import Foundation

/// Placement-level planners (ADR-0007): stale lock entries, dead links,
/// leftover host folders, link ↔ copy mode, and Vercel adoption of ownerless
/// skills.
extension CommandBatchBuilder {
    /// The ownership bucket (`user` / `project:<root>`) a workspace id
    /// belongs to: host workspaces (`host:<id>`, `project:<root>#<host>`)
    /// fold into their scope's bucket.
    static func bucket(of workspaceID: String) -> String {
        if workspaceID.hasPrefix("host:") {
            return "user"
        }
        if workspaceID.hasPrefix("project:"), let hash = workspaceID.firstIndex(of: "#") {
            return String(workspaceID[..<hash])
        }
        return workspaceID
    }

    /// The bucket a skill lives in, or nil when no project workspace holds
    /// it.
    static func bucket(of skill: Skill, report: ScanReport) -> String? {
        if skill.scope == .user {
            return "user"
        }
        return report.workspaces.lazy
            .filter { $0.kind == .project && !$0.id.contains("#") }
            .map(\.id)
            .first { id in
                let root = String(id.dropFirst("project:".count))
                return skill.placements.contains { $0.path.hasPrefix(root + "/") }
            }
    }

    // MARK: - stale lock entries and dead links

    /// `lock-without-files`: the lock records a skill whose files are gone.
    /// `npx skills remove` drops the entry and any dead links of that name;
    /// no skill files of the name exist in the scope, so nothing else is at
    /// risk.
    func staleLockCommands(entry: DecisionEntry, finding: Finding) throws -> [BatchCommand] {
        guard let name = finding.skillName else {
            throw DecisionProblem(
                message: "finding '\(entry.findingID)' (\(finding.ruleID)) has no skill name")
        }
        return [
            BatchCommandFactory.vercelRemove(
                name: name, scope: finding.workspaceID == "user" ? .user : .project,
                atRisk: [],
                intent: "Remove the stale lock entry for '\(name)' (finding \(finding.ruleID)): "
                    + "the lock lists it, but its files are gone.",
                consequence: .removesOnlyStaleLockEntry(skill: name),
                workingDirectory: projectRoot(of: finding))
        ]
    }

    /// `broken-symlink`: delete the dead link itself.
    func deadLinkCommands(entry: DecisionEntry, finding: Finding) throws -> [BatchCommand] {
        guard let path = finding.evidence.first(where: { $0.kind == "linkPath" })?.detail else {
            throw DecisionProblem(
                message: "finding '\(entry.findingID)' (\(finding.ruleID)) records no link path")
        }
        let name = finding.skillName ?? URL(fileURLWithPath: path).lastPathComponent
        return [
            BatchCommandFactory.deleteLink(
                name: name, path: path,
                intent: "Delete the dead link '\(path)' (finding \(finding.ruleID)): the "
                    + "folder it points to no longer exists.")
        ]
    }

    /// `leftover-host-dir`: delete the folder of links a CLI sprayed for an
    /// agent that is not installed.
    func leftoverHostCommands(entry: DecisionEntry, finding: Finding) throws -> [BatchCommand] {
        guard let path = finding.evidence.first(where: { $0.kind == "skillsDir" })?.detail else {
            throw DecisionProblem(
                message: "finding '\(entry.findingID)' (\(finding.ruleID)) records no folder")
        }
        let hosts = finding.evidence.first { $0.kind == "hosts" }?.detail ?? finding.workspaceID
        return [
            BatchCommandFactory.removeLeftoverSkillsDir(
                path: path, hosts: hosts,
                intent: "Remove the leftover folder '\(path)' (finding \(finding.ruleID)): "
                    + "\(hosts) is not installed, and the folder holds only links.")
        ]
    }

    // MARK: - link ↔ copy

    func relinkCommands(
        entry: DecisionEntry, finding: Finding, report: ScanReport
    ) throws -> [BatchCommand] {
        let skill = try resolveSkill(entry: entry, finding: finding, report: report)
        return try Self.relinkPlan(
            skill: skill, bucket: finding.workspaceID, report: report,
            reason: "finding \(finding.ruleID)")
    }

    /// Every host-folder copy of the skill, and every link resolving
    /// somewhere else (another manager's store), becomes a link to its copy
    /// in the scope's shared skills folder. Agent-managed copies are left
    /// alone.
    static func relinkPlan(
        skill: Skill, bucket: String, report: ScanReport, reason: String
    ) throws -> [BatchCommand] {
        let storeRoot = try sharedStoreRoot(skill: skill, bucket: bucket, report: report)
        guard
            let store = skill.placements.first(where: {
                $0.kind == .directory && parentDir($0.path) == storeRoot
            })
        else {
            throw DecisionProblem(
                message: "'\(skill.name)' has no copy in the shared skills folder "
                    + "(\(storeRoot)) to link to; install it there first")
        }
        let storeIdentity = store.canonicalPath ?? store.path
        let copies = skill.placements.filter { placement in
            switch placement.kind {
            case .directory:
                return placement.path != store.path && placement.managingAgent == nil
            case .symlink:
                return placement.canonicalPath != storeIdentity
            case .brokenSymlink:
                return false
            }
        }
        guard !copies.isEmpty else {
            throw DecisionProblem(message: "every placement of '\(skill.name)' is already a link")
        }
        return copies.map { copy in
            BatchCommandFactory.relink(
                name: skill.name, path: copy.path, storePath: store.path,
                diverged: copy.kind == .directory && copy.contentHash != store.contentHash,
                intent: "Link '\(copy.path)' to the shared copy of '\(skill.name)' "
                    + "(\(reason)) so every agent reads one copy.")
        }
    }

    /// Every link placement of the skill becomes a standalone copy.
    static func materializePlan(
        skill: Skill, bucket: String, report: ScanReport
    ) throws -> [BatchCommand] {
        let storeRoot = try sharedStoreRoot(skill: skill, bucket: bucket, report: report)
        let links = skill.placements.filter {
            $0.kind == .symlink && parentDir($0.path) != storeRoot
        }
        guard !links.isEmpty else {
            throw DecisionProblem(message: "every placement of '\(skill.name)' is already a copy")
        }
        return links.map { link in
            BatchCommandFactory.materialize(
                name: skill.name, path: link.path,
                intent: "Replace the link '\(link.path)' with its own copy of "
                    + "'\(skill.name)'.")
        }
    }

    private static func sharedStoreRoot(
        skill: Skill, bucket: String, report: ScanReport
    ) throws -> String {
        if skill.ownership == .agent {
            throw agentManaged(skill: skill)
        }
        guard let root = report.workspaces.first(where: { $0.id == bucket })?.root else {
            throw DecisionProblem(message: "no shared skills folder for scope '\(bucket)'")
        }
        return root
    }

    // MARK: - Vercel adoption

    func noDirectoryPlacements(skill: Skill, entry: DecisionEntry) -> DecisionProblem {
        DecisionProblem(
            message: "skill '\(skill.name)' (finding '\(entry.findingID)') has no "
                + "directory placements to act on")
    }

    func requireOwnerless(skill: Skill, entry: DecisionEntry) throws {
        guard skill.ownership == .ownerless else {
            throw DecisionProblem(
                message: "skill '\(skill.name)' (finding '\(entry.findingID)') is already "
                    + "owned by the \(skill.ownership.rawValue) ledger; 'adopt' applies "
                    + "only to ownerless skills")
        }
    }

    /// Adopts an ownerless skill into the Vercel ledger from a user-chosen
    /// source: `npx skills add <source> --skill <name>` for every host that
    /// holds a placement (the canonical store via its pinned host). The CLI
    /// replaces each existing copy with a link to the fresh shared copy
    /// (probe-verified against skills@1.7.0).
    func vercelAdoptCommands(
        skill: Skill, source: String, finding: Finding, report: ScanReport
    ) throws -> [BatchCommand] {
        var agents = Set<String>()
        for placement in skill.placements where placement.kind != .brokenSymlink {
            let dir = Self.parentDir(placement.path)
            guard let workspace = report.workspaces.first(where: { $0.root == dir }) else {
                throw DecisionProblem(
                    message: "cannot adopt '\(skill.name)': no agent installs into '\(dir)'")
            }
            guard !WorkspaceEnumerator.isLegacy(workspaceID: workspace.id) else {
                throw DecisionProblem(
                    message: "cannot adopt '\(skill.name)': '\(dir)' is a legacy folder the "
                        + "CLI no longer installs into")
            }
            agents.insert(Self.host(of: workspace))
        }
        return [
            BatchCommandFactory.vercelReinstall(
                name: skill.name, source: source, scope: skill.scope,
                agents: agents.sorted(),
                intent: "Adopt '\(skill.name)' (finding \(finding.ruleID)): install it from "
                    + "\(source) so the Vercel ledger tracks and updates it.",
                consequence: .replacesCopiesWithSharedLinks,
                workingDirectory: projectRoot(of: finding))
        ]
    }

    // MARK: - missing shared copy

    /// Restores a locked skill's shared copy from the lock's source. The
    /// re-install targets the agents still holding the skill, so their
    /// copies and foreign links become links to the restored copy, as the
    /// lock describes.
    func restoreSharedCopy(
        _ skill: Skill, entry: DecisionEntry, finding: Finding, report: ScanReport
    ) throws -> [BatchCommand] {
        let source = try recordedVercelSource(skill: skill, entry: entry)
        let reachable = Self.cliReachable(skill: skill, report: report)
        guard !reachable.isEmpty else {
            throw DecisionProblem(
                message: "cannot reinstall '\(skill.name)': no placement lies directly in a "
                    + "skills folder the CLI installs into")
        }
        let agents = Set(reachable.map { Self.host(of: $0.workspace) })
        return [
            BatchCommandFactory.vercelReinstall(
                name: skill.name, source: source, scope: skill.scope, agents: agents.sorted(),
                intent: "Restore the shared copy of '\(skill.name)' (finding "
                    + "\(finding.ruleID)): re-install it from the lock's recorded source.",
                consequence: .restoresSharedCopy(replacing: reachable.map(\.path)),
                workingDirectory: projectRoot(of: finding))
        ]
    }

    /// Removes a locked skill whose shared copy is gone: the lock entry and
    /// every placement the CLI reaches, agent-made copies included.
    func removeLockedSkill(
        entry: DecisionEntry, finding: Finding, report: ScanReport
    ) throws -> [BatchCommand] {
        let skill = try resolveSkill(entry: entry, finding: finding, report: report)
        guard skill.ownership == .vercel, !skill.ambiguous else {
            throw DecisionProblem(
                message: "skill '\(skill.name)' (finding '\(entry.findingID)') is not owned "
                    + "by the Vercel ledger alone; choose leave")
        }
        let paths = Self.cliReachable(skill: skill, report: report).map(\.path)
        return [
            BatchCommandFactory.vercelRemove(
                name: skill.name, scope: skill.scope, atRisk: [],
                intent: "Remove '\(skill.name)' (finding \(finding.ruleID)): its shared copy "
                    + "is gone; drop the lock entry and the copies agents still hold.",
                consequence: .removesLockedSkill(skill: skill.name, deleting: paths),
                workingDirectory: projectRoot(of: finding))
        ]
    }

    /// The skill's live placements `npx skills` acts on: those directly in a
    /// scanned skills folder the CLI still installs into. A copy an agent
    /// files deeper (Hermes's `<root>/<category>/<name>`) is outside
    /// `<root>/<name>` and untouched, as is a copy in a legacy folder.
    private static func cliReachable(
        skill: Skill, report: ScanReport
    ) -> [(path: String, workspace: Workspace)] {
        skill.placements.compactMap { placement in
            guard placement.kind != .brokenSymlink,
                let workspace = report.workspaces.first(where: {
                    $0.root == parentDir(placement.path)
                }),
                !WorkspaceEnumerator.isLegacy(workspaceID: workspace.id)
            else { return nil }
            return (placement.path, workspace)
        }
    }

    /// The host id lending a workspace its id; the scope's shared store
    /// installs through the canonical store host.
    private static func host(of workspace: Workspace) -> String {
        if workspace.id.hasPrefix("host:") {
            return String(workspace.id.dropFirst("host:".count))
        }
        if let hash = workspace.id.firstIndex(of: "#") {
            return String(workspace.id[workspace.id.index(after: hash)...])
        }
        return HostTable.canonicalStoreHost
    }
    /// The gh-provenanced placement's parent skills dir: recovered from the
    /// double-booked finding's `skillMdPath` evidence (contract-guaranteed
    /// for double-booked names), falling back to the first
    /// sorted placement dir.
    func ghProvenanceDir(
        skill: Skill, finding: Finding, report: ScanReport
    ) throws -> String {
        let arbitration = report.findings.first {
            $0.ruleID == "double-booked" && $0.skillName == skill.name
                && $0.workspaceID == finding.workspaceID
        }
        if let skillMD = arbitration?.evidence.first(where: { $0.kind == "skillMdPath" }) {
            return Self.parentDir(Self.parentDir(skillMD.detail))
        }
        let dirs = placementDirs(skill)
        guard let first = dirs.first else {
            throw DecisionProblem(
                message: "skill '\(skill.name)' has no directory placement to re-anchor")
        }
        return first
    }
}
