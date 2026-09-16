import Foundation

/// The per-action planners of `CommandBatchBuilder` (split out to keep each
/// file focused; internal to the module, exercised through the public
/// `build` seam).
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
        case .vercel:
            if finding.ruleID == "vercel-lock-drift" {
                let source = try recordedVercelSource(skill: skill, entry: entry)
                return [
                    BatchCommandFactory.vercelReinstall(
                        name: skill.name, source: source, scope: skill.scope,
                        intent: "Repair vercel-lock-drift on '\(skill.name)': re-install from "
                            + "the Vercel lock's recorded source (npx skills update reports "
                            + "'already up to date' and never rewrites drifted copies).",
                        consequence: "Content resets to upstream; local edits are lost.")
                ]
            }
            return [
                BatchCommandFactory.vercelUpdate(
                    name: skill.name, scope: skill.scope, finding: finding)
            ]
        case .github:
            let dirs = placementDirs(skill)
            guard !dirs.isEmpty else {
                throw noDirectoryPlacements(skill: skill, entry: entry)
            }
            return BatchCommandFactory.githubUpdates(
                name: skill.name, dirs: dirs, finding: finding)
        case .doubleBooked:
            throw needsArbitration(skill: skill, entry: entry)
        case .ownerless:
            throw DecisionProblem(
                message: "skill '\(skill.name)' (finding '\(entry.findingID)'): no ledger "
                    + "owns this skill — 'update' is not available; choose adopt, cleanup, "
                    + "or leave")
        }
    }

    // MARK: - arbitrate (D10)

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
            return [
                BatchCommandFactory.vercelReinstall(
                    name: skill.name, source: source, scope: skill.scope,
                    intent: "Arbitrate '\(skill.name)' keeping the Vercel ledger (finding "
                        + "\(finding.ruleID)): re-install from the lock's recorded source.",
                    consequence: "Content resets to upstream; local edits are lost. The "
                        + "re-install erases the GitHub frontmatter provenance.")
            ]
        case .keepGitHub:
            return try keepGitHubCommands(
                skill: skill, entry: entry, finding: finding, report: report)
        case .adoptSource:
            throw DecisionProblem(
                message: "action 'arbitrate' on finding '\(entry.findingID)' requires "
                    + "choice 'keep-vercel' or 'keep-github', not an adopt source")
        }
    }

    /// The D10 keep-github sequence: FIRST the danger-flagged
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
        let atRisk = [AtRiskSkill(skill: skill.name, ownership: skill.ownership.rawValue)]
        let remove = BatchCommandFactory.vercelRemove(
            name: skill.name, scope: skill.scope, finding: finding, atRisk: atRisk,
            intent: "Arbitrate '\(skill.name)' keeping the GitHub ledger (finding "
                + "\(finding.ruleID)): remove every copy by name before re-anchoring.")
        let install = BatchCommandFactory.githubInstall(
            repo: BatchCommandFactory.ownerRepo(from: provenance.repo),
            path: path,
            dir: dir,
            intent: "Re-install '\(skill.name)' from its recorded GitHub provenance "
                + "(\(provenance.repo)), re-anchoring the GitHub ledger.",
            consequence: "Content resets to the gh-recorded ref; local edits are lost.")
        return [remove, install]
    }

    /// The gh-provenanced placement's parent skills dir: recovered from the
    /// double-booked finding's `skillMdPath` evidence (contract-guaranteed
    /// for double-booked names, VAL-SCAN-016), falling back to the first
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

    // MARK: - adopt (D11)

    func adoptCommands(
        entry: DecisionEntry, finding: Finding, report: ScanReport
    ) throws -> [BatchCommand] {
        let skill = try resolveSkill(entry: entry, finding: finding, report: report)
        guard case .adoptSource(let repo, let path) = entry.choice else {
            throw DecisionProblem(
                message: "adopt on finding '\(entry.findingID)' requires a choice object "
                    + "with 'repo' (owner/repo) and 'path' (repo-relative skill path)")
        }
        guard skill.ownership == .ownerless else {
            throw DecisionProblem(
                message: "skill '\(skill.name)' (finding '\(entry.findingID)') is already "
                    + "owned by the \(skill.ownership.rawValue) ledger; 'adopt' applies "
                    + "only to ownerless skills")
        }
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
                consequence: "If upstream content differs from the on-disk payload, "
                    + "merge-overwrite keeps extra local files but overwrites colliding "
                    + "ones.")
        }
    }

    // MARK: - cleanup

    func cleanupCommands(
        entry: DecisionEntry, finding: Finding, report: ScanReport
    ) throws -> [BatchCommand] {
        let skill = try resolveSkill(entry: entry, finding: finding, report: report)
        if skill.ownership == .ownerless {
            // Ambiguous names land here too (attribution voided → ownerless
            // routing, VAL-REPAIR-057).
            let paths = skill.placements.filter { $0.kind == .directory }.map(\.path).sorted()
            guard !paths.isEmpty else {
                throw noDirectoryPlacements(skill: skill, entry: entry)
            }
            return BatchCommandFactory.ownerlessCleanups(
                name: skill.name, paths: paths, finding: finding)
        }
        // Ledger-owned skills remove through the vercel CLI (gh has no remove
        // command); cross-ledger names are named as at-risk (VAL-REPAIR-021).
        let atRisk: [AtRiskSkill] =
            skill.ownership == .vercel
            ? [] : [AtRiskSkill(skill: skill.name, ownership: skill.ownership.rawValue)]
        return [
            BatchCommandFactory.vercelRemove(
                name: skill.name, scope: skill.scope, finding: finding, atRisk: atRisk,
                intent: "Remove '\(skill.name)' (finding \(finding.ruleID)): npx skills "
                    + "remove is the only scriptable removal; gh has no remove command.")
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

    func needsArbitration(skill: Skill, entry: DecisionEntry) -> DecisionProblem {
        DecisionProblem(
            message: "skill '\(skill.name)' (finding '\(entry.findingID)') is "
                + "double-booked: repair requires an explicit surviving-ledger choice — "
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

    func noDirectoryPlacements(skill: Skill, entry: DecisionEntry) -> DecisionProblem {
        DecisionProblem(
            message: "skill '\(skill.name)' (finding '\(entry.findingID)') has no "
                + "directory placements to act on")
    }
}
