import Foundation

/// Placement-level planners (ADR-0007): stale lock entries, dead links,
/// link ↔ copy mode, and Vercel adoption of ownerless skills.
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
                finding: finding, atRisk: [],
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
}
