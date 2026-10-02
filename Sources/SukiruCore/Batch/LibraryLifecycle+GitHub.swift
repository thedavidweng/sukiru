import Foundation

/// Planning of Library requests into batch commands, and the gh re-install
/// shapes behind pin, unpin, and restore (probe-verified against gh
/// 2.102.0; docs/collision-matrix.md, 2026-10-02 pin/unpin run).
extension CommandBatchBuilder {
    /// Plans every Library request into `planned`. Updates and unpins are
    /// grouped, since both CLIs accept several names in one run: one
    /// `npx skills update` per scope, one `gh skill update` per skills dir.
    /// Pins and restores carry per-skill arguments (the ref, the pin
    /// state), so each becomes one `gh skill install` per placement dir.
    func planLifecycle(
        _ requests: [LifecycleRequest], report: ScanReport, into planned: inout PlannedDecisions
    ) {
        var groups = LifecycleGroups()
        for request in requests.sorted(by: { $0.id < $1.id }) {
            do {
                let bucket = try self.bucket(of: request, report: report)
                try groups.add(request, bucket: bucket, dirs: placementDirs(request.skill))
                planned.refs.append(
                    FindingRef(
                        findingID: request.id, ruleID: request.action.ruleID,
                        skillName: request.skill.name, workspaceID: bucket))
            } catch {
                planned.problems.append((error as? DecisionProblem)?.message ?? "\(error)")
            }
        }
        for command in groups.commands
        where !planned.commands.contains(where: { $0.argv == command.argv }) {
            planned.commands.append(command)
        }
    }

    /// The request's ownership bucket, once it is known to apply to the
    /// current scan.
    private func bucket(of request: LifecycleRequest, report: ScanReport) throws -> String {
        let skill = request.skill
        guard report.skills.contains(skill), let bucket = Self.bucket(of: skill, report: report)
        else {
            throw DecisionProblem(
                message: "skill '\(skill.name)' is not in the current scan; queue it again")
        }
        let blocker = Self.lifecycleBlocker(
            skill: skill, action: request.action, capabilities: nil, report: report)
        if let blocker {
            throw DecisionProblem(message: blocker.refusal(request.action, skill: skill))
        }
        return bucket
    }

    /// The recorded gh install source (owner/repo + exact SKILL.md path),
    /// for the pin and restore re-anchoring shapes.
    private static func githubInstallSource(
        _ skill: Skill, action: LifecycleAction
    ) throws -> (repo: String, path: String) {
        guard let provenance = skill.provenance.github,
            let path = provenance.path, !path.isEmpty
        else {
            throw DecisionProblem(
                message: "cannot \(action.rawValue) '\(skill.name)': recorded GitHub "
                    + "provenance is incomplete (repo/path missing)")
        }
        // Probe-verified: the recorded `github-path` is the skill's
        // repo-relative DIRECTORY, but `gh skill install` requires the exact
        // SKILL.md path — a bare directory fails with "no skills found".
        let installPath = path.hasSuffix(".md") ? path : path + "/SKILL.md"
        return (BatchCommandFactory.ownerRepo(from: provenance.repo), installPath)
    }

    /// Pin one GitHub-ledger skill: `gh skill install <repo> <path>
    /// --pin <ref> --force --dir <dir>` per placement dir. The re-install
    /// sets `github-pinned` (and the global lock's `pinnedRef`) and
    /// merge-overwrites content to the pinned ref, keeping extra local
    /// files.
    static func githubPinCommands(
        _ skill: Skill, ref: String?, dirs: [String]
    ) throws -> [BatchCommand] {
        guard let ref, LifecycleRequest.isValidPinRef(ref) else {
            throw DecisionProblem(
                message: "cannot pin '\(skill.name)': the pin ref is empty or contains "
                    + "whitespace or control characters")
        }
        let source = try githubInstallSource(skill, action: .pin)
        guard !dirs.isEmpty else {
            throw DecisionProblem(
                message: "skill '\(skill.name)' has no directory placement for "
                    + "gh skill install --pin")
        }
        return dirs.map { dir in
            BatchCommandFactory.githubInstall(
                repo: source.repo,
                path: source.path,
                dir: dir,
                pinRef: ref,
                intent: "Pin '\(skill.name)' to \(ref) (requested in the Library): "
                    + "gh skill install --pin, re-anchoring the GitHub ledger.",
                consequence: .pinsGitHubSkill(ref: ref))
        }
    }

    /// Restore a GitHub-ledger skill's files to the recorded version:
    /// `gh skill install <repo> <path> [--pin <ref>] --force --dir <dir>`
    /// per placement dir. `gh skill update --force` would silently SKIP a
    /// pinned skill and delete extra local files; the re-install shape
    /// merge-overwrites files that differ (extras kept) and works whether
    /// or not the skill is pinned — the pin must be passed back, since an
    /// unpinned re-install clears it.
    static func githubRestoreCommands(
        _ skill: Skill, dirs: [String]
    ) throws -> [BatchCommand] {
        let source = try githubInstallSource(skill, action: .restore)
        guard !dirs.isEmpty else {
            throw DecisionProblem(
                message: "skill '\(skill.name)' has no directory placement for "
                    + "gh skill install --force")
        }
        let pinned = skill.provenance.github?.pinned == true
        let pinRef = pinned ? skill.provenance.github?.pinnedRef : nil
        if pinned, pinRef == nil {
            throw DecisionProblem(
                message: "cannot restore '\(skill.name)': the skill is pinned but the "
                    + "recorded pin ref is missing, and a re-install without it would "
                    + "silently clear the pin")
        }
        let version = pinRef ?? "the latest of the recorded branch"
        return dirs.map { dir in
            BatchCommandFactory.githubInstall(
                repo: source.repo,
                path: source.path,
                dir: dir,
                pinRef: pinRef,
                intent: "Restore '\(skill.name)' to \(version) (requested in the "
                    + "Library): gh skill install --force, re-downloading the recorded "
                    + "version over local edits; files added locally are kept.",
                consequence: .mergeOverwritesCollidingFiles)
        }
    }
}

/// Library commands collected across requests: removals and per-skill gh
/// re-installs (pin, restore) as they come, update and unpin names grouped
/// by scope (npx) or skills dir (gh).
struct LifecycleGroups {
    private var removals: [BatchCommand] = []
    private var reinstalls: [BatchCommand] = []
    private var vercelNames: [String: [String]] = [:]
    private var githubNames: [String: [String]] = [:]
    private var githubUnpinNames: [String: [String]] = [:]

    mutating func add(_ request: LifecycleRequest, bucket: String, dirs: [String]) throws {
        let skill = request.skill
        switch (request.action, skill.ownership) {
        case (.update, .github):
            try addGitHubNames(&githubNames, skill: skill, dirs: dirs, command: "gh skill update")
        case (.update, _):
            vercelNames[bucket, default: []].append(skill.name)
        case (.uninstall, .github):
            removals += CommandBatchBuilder.githubUninstall(skill)
        case (.uninstall, _):
            removals.append(Self.vercelRemoval(skill, bucket: bucket))
        case (.pin, .github):
            reinstalls += try CommandBatchBuilder.githubPinCommands(
                skill, ref: request.pinRef, dirs: dirs)
        case (.restore, .github):
            reinstalls += try CommandBatchBuilder.githubRestoreCommands(skill, dirs: dirs)
        case (.unpin, .github):
            try addGitHubNames(
                &githubUnpinNames, skill: skill, dirs: dirs, command: "gh skill update --unpin")
        case (.pin, _), (.unpin, _), (.restore, _):
            // Unreachable: `lifecycleBlocker` refuses these pairings first.
            throw DecisionProblem(
                message: LifecycleBlocker.githubLedgerOnly.refusal(
                    request.action, skill: skill))
        }
    }

    private func addGitHubNames(
        _ names: inout [String: [String]], skill: Skill, dirs: [String], command: String
    ) throws {
        guard !dirs.isEmpty else {
            throw DecisionProblem(
                message: "skill '\(skill.name)' has no directory placement for \(command)")
        }
        for dir in dirs {
            names[dir, default: []].append(skill.name)
        }
    }

    private static func vercelRemoval(_ skill: Skill, bucket: String) -> BatchCommand {
        BatchCommandFactory.vercelRemove(
            name: skill.name, scope: skill.scope,
            atRisk: BatchCommandFactory.removalAtRisk(skill),
            intent: "Uninstall '\(skill.name)' (requested in the Library): "
                + "npx skills remove drops its lock entry and placements.",
            workingDirectory: CommandBatchBuilder.projectRoot(ofBucket: bucket))
    }

    var commands: [BatchCommand] {
        let reason = "requested in the Library"
        let vercel = vercelNames.keys.sorted().map { bucket in
            BatchCommandFactory.vercelUpdate(
                names: vercelNames[bucket] ?? [], scope: bucket == "user" ? .user : .project,
                reason: reason, workingDirectory: CommandBatchBuilder.projectRoot(ofBucket: bucket))
        }
        let github = githubNames.keys.sorted().map { dir in
            BatchCommandFactory.githubUpdate(
                names: githubNames[dir] ?? [], dir: dir, reason: reason)
        }
        let unpins = githubUnpinNames.keys.sorted().map { dir in
            BatchCommandFactory.githubUnpin(
                names: githubUnpinNames[dir] ?? [], dir: dir, reason: reason)
        }
        return removals + vercel + github + unpins + reinstalls
    }
}
