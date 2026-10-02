import Foundation

/// The per-action planners of `CommandBatchBuilder` (split out to keep each
/// file focused; internal to the module, exercised through the public
/// `build` entry point).
extension CommandBatchBuilder {
    // MARK: - skill resolution

    /// Resolves the finding's (name, scope group) to the report's Skill.
    /// Findings anchor to scope groups (`user` / `project:<root>`); project
    /// skills match their group's root by placement path prefix.
    func resolveSkill(
        entry: DecisionEntry, finding: Finding, report: ScanReport
    ) throws -> Skill {
        guard let name = finding.skillName else {
            throw DecisionProblem(
                message: "finding '\(entry.findingID)' (\(finding.ruleID)) has no skill "
                    + "target; only 'leave' applies")
        }
        let candidates = report.skills.filter { $0.name == name }
        let match: Skill?
        if finding.workspaceID == "user" {
            match = candidates.first { $0.scope == .user }
        } else if finding.workspaceID.hasPrefix("project:") {
            let root = String(finding.workspaceID.dropFirst("project:".count))
            match = candidates.first { skill in
                skill.scope == .project
                    && skill.placements.contains { $0.path.hasPrefix(root + "/") }
            }
        } else {
            match = nil
        }
        guard let skill = match else {
            throw DecisionProblem(
                message: "skill '\(name)' (finding '\(entry.findingID)') has no on-disk "
                    + "placement in scope '\(finding.workspaceID)'; only 'leave' applies")
        }
        return skill
    }

    /// Distinct parent skills dirs of the skill's directory placements,
    /// sorted (gh `--dir` targets; ownerless cleanup paths derive likewise).
    func placementDirs(_ skill: Skill) -> [String] {
        let dirs = skill.placements.filter { $0.kind == .directory }.map {
            Self.parentDir($0.path)
        }
        return Array(Set(dirs)).sorted()
    }

    static func parentDir(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    /// The targeted re-install shape for a project-scope skill
    /// (probe-verified against skills@1.5.26): an untargeted
    /// `npx skills add … --skill <name>` refreshes ONLY the canonical
    /// `.agents/skills` copy — drifted or gh-overwritten copies in other
    /// host dirs are left untouched, findings included. So when the skill
    /// has placements outside the canonical store, the reinstall names
    /// every placement's host (`-a <host>…`, the canonical store via its
    /// pinned `codex` host entry) and adds `--copy` when a physical copy
    /// lives outside the canonical store. Symlink-only extra placements
    /// install in link mode (no `--copy`). Canonical-only placements and
    /// user scope keep the plain shape.
    func reinstallTargets(skill: Skill, finding: Finding) throws -> (
        agents: [String], copy: Bool
    ) {
        guard let root = projectRoot(of: finding) else { return ([], false) }
        let canonicalDir = root + "/" + HostTable.canonicalProjectSkillDir
        var agents = Set<String>()
        var hasCanonical = false
        var hasExternalCopy = false
        for placement in skill.placements where placement.kind != .brokenSymlink {
            let skillsDir = Self.parentDir(placement.path)
            if skillsDir == canonicalDir {
                hasCanonical = true
                continue
            }
            guard skillsDir.hasPrefix(root + "/") else {
                throw DecisionProblem(
                    message: "cannot repair '\(skill.name)': placement '\(placement.path)' "
                        + "lies outside the project root; a targeted reinstall cannot "
                        + "be derived")
            }
            let relative = String(skillsDir.dropFirst(root.count + 1))
            guard let host = HostTable.host(forProjectSkillDir: relative) else {
                throw DecisionProblem(
                    message: "cannot repair '\(skill.name)': no known host installs into "
                        + "'\(relative)'; a targeted reinstall cannot be derived")
            }
            agents.insert(host)
            if placement.kind == .directory {
                hasExternalCopy = true
            }
        }
        guard !agents.isEmpty else { return ([], false) }
        if hasCanonical {
            agents.insert(HostTable.canonicalStoreHost)
        }
        return (agents.sorted(), hasExternalCopy)
    }

    /// The project root a finding belongs to (nil for user scope). npx `-p`
    /// commands resolve the project literally from the process cwd, so
    /// project-scope vercel commands carry it as their workingDirectory.
    func projectRoot(of finding: Finding) -> String? {
        guard finding.workspaceID.hasPrefix("project:") else {
            return nil
        }
        return String(finding.workspaceID.dropFirst("project:".count))
    }

    // MARK: - update

    func updateCommands(
        entry: DecisionEntry, finding: Finding, report: ScanReport
    ) throws -> [BatchCommand] {
        let skill = try resolveSkill(entry: entry, finding: finding, report: report)
        if skill.ambiguous {
            throw DecisionProblem(
                message: "skill '\(skill.name)' (finding '\(entry.findingID)') is ambiguous: "
                    + "ownership attribution is voided, so 'update' is not available; "
                    + "choose adopt, cleanup, or leave")
        }
        switch skill.ownership {
        case .vercel where finding.ruleID == MissingSharedCopyRule.ruleID:
            return try restoreSharedCopy(skill, entry: entry, finding: finding, report: report)
        case .vercel:
            if finding.ruleID == "vercel-lock-drift" {
                let source = try recordedVercelSource(skill: skill, entry: entry)
                let targets = try reinstallTargets(skill: skill, finding: finding)
                return [
                    BatchCommandFactory.vercelReinstall(
                        name: skill.name, source: source, scope: skill.scope,
                        agents: targets.agents, copy: targets.copy,
                        intent: "Repair vercel-lock-drift on '\(skill.name)': re-install from "
                            + "the Vercel lock's recorded source (npx skills update reports "
                            + "'already up to date' and never rewrites drifted copies).",
                        consequence: .resetsToUpstream,
                        workingDirectory: projectRoot(of: finding))
                ]
            }
            return [
                BatchCommandFactory.vercelUpdate(
                    names: [skill.name], scope: skill.scope, reason: "finding \(finding.ruleID)",
                    workingDirectory: projectRoot(of: finding))
            ]
        case .github:
            return try githubUpdateCommands(
                skill, entry: entry, finding: finding, report: report)
        case .doubleBooked:
            throw needsArbitration(skill: skill, entry: entry)
        case .ownerless:
            throw DecisionProblem(
                message: "skill '\(skill.name)' (finding '\(entry.findingID)'): no ledger "
                    + "owns this skill, so 'update' is not available; choose adopt, cleanup, "
                    + "or leave")
        case .agent:
            throw Self.agentManaged(skill: skill)
        }
    }

    // MARK: - arbitrate

    func arbitrateCommands(
        entry: DecisionEntry, finding: Finding, report: ScanReport
    ) throws -> [BatchCommand] {
        let skill = try resolveSkill(entry: entry, finding: finding, report: report)
        guard let choice = entry.choice else {
            throw DecisionProblem(
                message: "arbitrate on finding '\(entry.findingID)' requires an explicit "
                    + "surviving-ledger choice: 'keep-vercel' or 'keep-github' (exactly "
                    + "two options, no default)")
        }
        guard skill.ownership == .doubleBooked else {
            throw notDoubleBooked(skill: skill, entry: entry)
        }
        switch choice {
        case .keepVercel:
            let source = try recordedVercelSource(skill: skill, entry: entry)
            let targets = try reinstallTargets(skill: skill, finding: finding)
            return [
                BatchCommandFactory.vercelReinstall(
                    name: skill.name, source: source, scope: skill.scope,
                    agents: targets.agents, copy: targets.copy,
                    intent: "Arbitrate '\(skill.name)' keeping the Vercel ledger (finding "
                        + "\(finding.ruleID)): re-install from the lock's recorded source.",
                    consequence: .resetsToUpstreamErasingGitHubProvenance,
                    workingDirectory: projectRoot(of: finding))
            ]
        case .keepGitHub:
            return try keepGitHubCommands(
                skill: skill, entry: entry, finding: finding, report: report)
        case .adoptSource, .adoptVercel:
            throw DecisionProblem(
                message: "action 'arbitrate' on finding '\(entry.findingID)' requires "
                    + "choice 'keep-vercel' or 'keep-github', not an adopt source")
        }
    }

    /// The keep-github arbitration sequence: FIRST the danger-flagged
    /// `npx skills remove` (deleting by name across ownership is the point),
    /// THEN `gh skill install <repo> <path> --force --dir <dir>` re-anchoring
    /// from the recorded gh provenance.
    func keepGitHubCommands(
        skill: Skill, entry: DecisionEntry, finding: Finding, report: ScanReport
    ) throws -> [BatchCommand] {
        guard let provenance = skill.provenance.github,
            let path = provenance.path, !path.isEmpty
        else {
            throw DecisionProblem(
                message: "skill '\(skill.name)' (finding '\(entry.findingID)'): recorded "
                    + "GitHub provenance is incomplete (repo/path missing); cannot "
                    + "re-anchor to the GitHub ledger")
        }
        let dir = try ghProvenanceDir(skill: skill, finding: finding, report: report)
        let blocker = Self.githubWriteBlocker(
            skillName: skill.name, report: report, replacing: skill)
        if let blocker {
            throw DecisionProblem(
                message: "cannot keep the GitHub ledger for '\(skill.name)': \(blocker.message)")
        }
        let atRisk = [AtRiskSkill(skill: skill.name, ownership: skill.ownership.rawValue)]
        let remove = BatchCommandFactory.vercelRemove(
            name: skill.name, scope: skill.scope, atRisk: atRisk,
            intent: "Arbitrate '\(skill.name)' keeping the GitHub ledger (finding "
                + "\(finding.ruleID)): remove every copy by name before re-anchoring.",
            workingDirectory: projectRoot(of: finding))
        // Probe-verified: the recorded `github-path` is the
        // skill's repo-relative DIRECTORY, but `gh skill install` requires
        // the exact SKILL.md path — a bare directory fails with
        // "no skills found".
        let installPath = path.hasSuffix(".md") ? path : path + "/SKILL.md"
        let install = BatchCommandFactory.githubInstall(
            repo: BatchCommandFactory.ownerRepo(from: provenance.repo),
            path: installPath,
            dir: dir,
            intent: "Re-install '\(skill.name)' from its recorded GitHub provenance "
                + "(\(provenance.repo)), re-anchoring the GitHub ledger.",
            consequence: .resetsToGitHubRef)
        return [remove, install]
    }

    // MARK: - adopt

    func adoptCommands(
        entry: DecisionEntry, finding: Finding, report: ScanReport
    ) throws -> [BatchCommand] {
        let skill = try resolveSkill(entry: entry, finding: finding, report: report)
        switch entry.choice {
        case .adoptSource(let repo, let path):
            try requireOwnerless(skill: skill, entry: entry)
            if let blocker = Self.githubWriteBlocker(skillName: skill.name, report: report) {
                throw DecisionProblem(
                    message: "cannot adopt '\(skill.name)' into the GitHub ledger: "
                        + blocker.message)
            }
            return try githubAdoptCommands(
                skill: skill, repo: repo, path: path, entry: entry, finding: finding)
        case .adoptVercel(let source):
            try requireOwnerless(skill: skill, entry: entry)
            return try vercelAdoptCommands(
                skill: skill, source: source, finding: finding, report: report)
        default:
            throw DecisionProblem(
                message: "adopt on finding '\(entry.findingID)' requires a choice object "
                    + "with 'source' (Vercel install source), or 'repo' (owner/repo) and "
                    + "'path' (repo-relative skill path) for GitHub")
        }
    }

    private func githubAdoptCommands(
        skill: Skill, repo: String, path: String, entry: DecisionEntry, finding: Finding
    ) throws -> [BatchCommand] {
        let dirs = placementDirs(skill)
        guard !dirs.isEmpty else {
            throw noDirectoryPlacements(skill: skill, entry: entry)
        }
        return dirs.map { dir in
            BatchCommandFactory.githubInstall(
                repo: repo,
                path: path,
                dir: dir,
                intent: "Adopt ownerless skill '\(skill.name)' into the GitHub ledger "
                    + "(finding \(finding.ruleID)): install from \(repo) path \(path), "
                    + "re-anchoring provenance onto the existing directory.",
                consequence: .mergeOverwritesCollidingFiles)
        }
    }

    // MARK: - cleanup

    func cleanupCommands(
        entry: DecisionEntry, finding: Finding, report: ScanReport
    ) throws -> [BatchCommand] {
        switch finding.ruleID {
        case "lock-without-files":
            return try staleLockCommands(entry: entry, finding: finding)
        case "broken-symlink":
            return try deadLinkCommands(entry: entry, finding: finding)
        case LeftoverHostRule.ruleID:
            return try leftoverHostCommands(entry: entry, finding: finding)
        case MissingSharedCopyRule.ruleID:
            return try removeLockedSkill(entry: entry, finding: finding, report: report)
        default:
            break
        }
        let skill = try resolveSkill(entry: entry, finding: finding, report: report)
        if skill.ownership == .agent {
            throw Self.agentManaged(skill: skill)
        }
        if skill.ownership == .ownerless {
            // Ambiguous names land here too (attribution voided → ownerless
            // routing).
            let paths = skill.placements.filter { $0.kind == .directory }.map(\.path).sorted()
            guard !paths.isEmpty else {
                throw noDirectoryPlacements(skill: skill, entry: entry)
            }
            // Links into the deleted payload would be left dangling.
            let links = skill.placements.filter { $0.kind != .directory }.map { link in
                BatchCommandFactory.deleteLink(
                    name: skill.name, path: link.path,
                    intent: "Delete the link '\(link.path)' to ownerless skill "
                        + "'\(skill.name)' (finding \(finding.ruleID)).")
            }
            return links
                + BatchCommandFactory.ownerlessCleanups(
                    name: skill.name, paths: paths, finding: finding)
        }
        // gh has no remove command; its record lives in the skill's own
        // frontmatter, so removal is the Library's direct deletion
        // (ADR-0004 amendment) rather than a name-based npx skills remove.
        if skill.ownership == .github {
            return Self.githubUninstall(skill, reason: "finding \(finding.ruleID)")
        }
        // Vercel-owned and double-booked names remove through the vercel CLI;
        // cross-ledger names are named as at-risk.
        return [
            BatchCommandFactory.vercelRemove(
                name: skill.name, scope: skill.scope,
                atRisk: BatchCommandFactory.removalAtRisk(skill),
                intent: "Remove '\(skill.name)' (finding \(finding.ruleID)): npx skills "
                    + "remove is the only scriptable removal; gh has no remove command.",
                workingDirectory: projectRoot(of: finding))
        ]
    }

    // MARK: - shared refusals

    func recordedVercelSource(skill: Skill, entry: DecisionEntry) throws -> String {
        guard let source = skill.provenance.vercel?.source, !source.isEmpty else {
            throw DecisionProblem(
                message: "skill '\(skill.name)' (finding '\(entry.findingID)'): the Vercel "
                    + "lock entry has no recorded source; cannot re-install")
        }
        return source
    }

    static func agentManaged(skill: Skill) -> DecisionProblem {
        DecisionProblem(
            message: "skill '\(skill.name)' is managed by \(skill.managingAgent ?? "its agent") "
                + "through the agent's own ledger; manage it in that agent")
    }

    func needsArbitration(skill: Skill, entry: DecisionEntry) -> DecisionProblem {
        DecisionProblem(
            message: "skill '\(skill.name)' (finding '\(entry.findingID)') is "
                + "double-booked: repair requires an explicit surviving-ledger choice; "
                + "use action 'arbitrate' with choice 'keep-vercel' or 'keep-github' "
                + "(no default)")
    }

    func notDoubleBooked(skill: Skill, entry: DecisionEntry) -> DecisionProblem {
        if skill.ambiguous {
            return DecisionProblem(
                message: "skill '\(skill.name)' (finding '\(entry.findingID)') is "
                    + "ambiguous: ownership attribution is voided, so 'arbitrate' does "
                    + "not apply; choose adopt, cleanup, or leave")
        }
        return DecisionProblem(
            message: "skill '\(skill.name)' (finding '\(entry.findingID)') is not "
                + "double-booked (ownership: \(skill.ownership.rawValue)); 'arbitrate' "
                + "applies only to double-booked skills")
    }
}
