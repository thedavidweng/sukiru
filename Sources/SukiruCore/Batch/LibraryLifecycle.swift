import Foundation

/// A change the user asks for on a ledger-owned skill from the Library,
/// rather than as the repair of a finding.
public enum LifecycleAction: String, Codable, Equatable, Sendable, CaseIterable {
    case update
    case uninstall

    /// The synthetic finding-ref rule ID (like `new-install`): the executor's
    /// snapshot, bounds, and rescan derive their scope from finding refs.
    public var ruleID: String { "library-\(rawValue)" }
}

/// One queued Library change: the skill as the current scan reports it.
public struct LifecycleRequest: Identifiable, Equatable, Sendable {
    public let skill: Skill
    public let action: LifecycleAction

    public init(skill: Skill, action: LifecycleAction) {
        self.skill = skill
        self.action = action
    }

    /// Also the synthetic finding ID of the batch ref the request produces,
    /// so a caller can tell which requests an executed batch carried.
    public var id: String {
        [action.ruleID, skill.scope.rawValue, skill.name, skill.placements.first?.path ?? "-"]
            .joined(separator: "|")
    }
}

/// Why the Library cannot offer an action for a skill.
public enum LifecycleBlocker: Equatable, Sendable {
    /// Both ledgers claim the skill: a surviving ledger must be chosen first.
    case doubleBooked
    /// Distinct copies disagree, so ownership attribution is voided.
    case ambiguous
    /// A host manages the skill through its own records.
    case agentManaged
    /// No ledger records the skill (Library offers deletion or adoption).
    case ownerless
    /// The owning ledger's CLI is `npx skills`, and npx is missing.
    case needsNpx
    /// The owning ledger's CLI is `gh skill`, and gh is unavailable.
    case needsGitHubCLI
    /// gh would write the user-scope Vercel lock record of this name (see
    /// `CommandBatchBuilder.githubWriteTouchesVercelRecord`).
    case touchesVercelRecord

    /// Human-readable refusal (English by design, like other core refusals).
    var message: String {
        switch self {
        case .doubleBooked:
            return "both ledgers claim this skill; choose a surviving ledger in Health first"
        case .ambiguous:
            return "ownership is ambiguous, so no ledger may act on this skill"
        case .agentManaged:
            return "an agent manages this skill through its own records"
        case .ownerless:
            return "no ledger owns this skill"
        case .needsNpx:
            return "the Vercel ledger's CLI (npx skills) is not available"
        case .needsGitHubCLI:
            return "the GitHub ledger's CLI (gh skill) is not available"
        case .touchesVercelRecord:
            return "gh skill also records the skill under its name in the Vercel ledger's "
                + "global lock, which would claim a user-scope skill of this name for the "
                + "Vercel ledger"
        }
    }

    /// The refusal for `action` on `skill`, as the batch builder phrases it.
    public func refusal(_ action: LifecycleAction, skill: Skill) -> String {
        "cannot \(action.rawValue) '\(skill.name)': \(message)"
    }
}

extension CommandBatchBuilder {
    /// Whether the Library can queue `action` for `skill`. Capabilities not
    /// yet probed (nil) block nothing, as with one-click fixes; without a
    /// report, the cross-scope Vercel record check is skipped. A GitHub
    /// uninstall deletes files directly, so it needs no `gh`.
    public static func lifecycleBlocker(
        skill: Skill, action: LifecycleAction, capabilities: CapabilityReport?,
        report: ScanReport? = nil
    ) -> LifecycleBlocker? {
        if skill.ambiguous {
            return .ambiguous
        }
        switch skill.ownership {
        case .doubleBooked:
            return .doubleBooked
        case .agent:
            return .agentManaged
        case .ownerless:
            return .ownerless
        case .vercel:
            return capabilities?.npx.canRunSkills == false ? .needsNpx : nil
        case .github:
            guard action == .update else { return nil }
            if capabilities?.github.available == false {
                return .needsGitHubCLI
            }
            if let report, githubWriteTouchesVercelRecord(skill, report: report) {
                return .touchesVercelRecord
            }
            return nil
        }
    }

    /// Every `gh skill` install or update also writes `~/.agents/.skill-lock.json`,
    /// the Vercel ledger's global lock, keyed by the bare skill name whatever
    /// the scope or `--dir` (gh 2.102.0 `lockfile.RecordInstall`;
    /// probe-verified in docs/collision-matrix.md). Such a write claims a
    /// user-scope skill for the Vercel ledger: the skill itself when it is
    /// user scope (it turns double-booked), or a user-scope skill of the same
    /// name whose Vercel record it rewrites.
    static func githubWriteTouchesVercelRecord(_ skill: Skill, report: ScanReport) -> Bool {
        skill.scope == .user
            || report.skills.contains {
                $0.scope == .user && $0.name == skill.name && $0.provenance.vercel != nil
            }
    }

    /// A Health update of a GitHub-ledger skill: one `gh skill update` per
    /// skills dir, under the same Vercel-record guard as the Library.
    func githubUpdateCommands(
        _ skill: Skill, entry: DecisionEntry, finding: Finding, report: ScanReport
    ) throws -> [BatchCommand] {
        let dirs = placementDirs(skill)
        guard !dirs.isEmpty else {
            throw noDirectoryPlacements(skill: skill, entry: entry)
        }
        if Self.githubWriteTouchesVercelRecord(skill, report: report) {
            throw DecisionProblem(
                message: LifecycleBlocker.touchesVercelRecord.refusal(.update, skill: skill))
        }
        return dirs.map { dir in
            BatchCommandFactory.githubUpdate(
                names: [skill.name], dir: dir, reason: "finding \(finding.ruleID)")
        }
    }

    /// Plans every Library request into `planned`. Updates are grouped, since
    /// both CLIs accept several names in one run: one `npx skills update`
    /// per scope, one `gh skill update` per skills dir.
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

    /// Deletes every placement of a GitHub-ledger skill: links (live or
    /// dead) as links, never following them, then the directories.
    static func githubUninstall(
        _ skill: Skill, reason: String = "requested in the Library"
    ) -> [BatchCommand] {
        let intent =
            "Uninstall '\(skill.name)' (\(reason)): gh skill has no "
            + "uninstall command, so its placements are deleted directly."
        let placements = skill.placements.sorted { $0.path < $1.path }
        let links = placements.filter { $0.kind != .directory }.map {
            BatchCommandFactory.deleteLink(name: skill.name, path: $0.path, intent: intent)
        }
        let dirs = placements.filter { $0.kind == .directory }.map {
            BatchCommandFactory.deleteGitHubSkillDirectory(
                name: skill.name, path: $0.path, intent: intent)
        }
        return links + dirs
    }

    static func projectRoot(ofBucket bucket: String) -> String? {
        bucket.hasPrefix("project:") ? String(bucket.dropFirst("project:".count)) : nil
    }
}

/// Library commands collected across requests: removals as they come,
/// update names grouped by scope (npx) or skills dir (gh).
private struct LifecycleGroups {
    private var removals: [BatchCommand] = []
    private var vercelNames: [String: [String]] = [:]
    private var githubNames: [String: [String]] = [:]

    mutating func add(_ request: LifecycleRequest, bucket: String, dirs: [String]) throws {
        let skill = request.skill
        switch (request.action, skill.ownership) {
        case (.update, .github):
            guard !dirs.isEmpty else {
                throw DecisionProblem(
                    message: "skill '\(skill.name)' has no directory placement for "
                        + "gh skill update")
            }
            for dir in dirs {
                githubNames[dir, default: []].append(skill.name)
            }
        case (.update, _):
            vercelNames[bucket, default: []].append(skill.name)
        case (.uninstall, .github):
            removals += CommandBatchBuilder.githubUninstall(skill)
        case (.uninstall, _):
            removals.append(
                BatchCommandFactory.vercelRemove(
                    name: skill.name, scope: skill.scope,
                    atRisk: BatchCommandFactory.removalAtRisk(skill),
                    intent: "Uninstall '\(skill.name)' (requested in the Library): "
                        + "npx skills remove drops its lock entry and placements.",
                    workingDirectory: CommandBatchBuilder.projectRoot(ofBucket: bucket)))
        }
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
        return removals + vercel + github
    }
}
