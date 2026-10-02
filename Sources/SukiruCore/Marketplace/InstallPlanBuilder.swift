import Foundation

/// The installer a new skill lands in. Each choice routes the
/// install through exactly one official CLI → one ledger; the UI must spell
/// out the consequences before the batch is built.
public enum InstallerChoice: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    /// `npx skills add` → the Vercel lockfile ledger.
    case vercel
    /// `gh skill install` → the GitHub frontmatter ledger.
    case github

    /// The owning-CLI badge the batch commands carry.
    public var owningCLI: OwningCLI {
        switch self {
        case .vercel: .vercel
        case .github: .github
        }
    }

    /// The executable the installer shells out to.
    public var executable: String {
        switch self {
        case .vercel: "npx"
        case .github: "gh"
        }
    }

    /// Which capability gate the sheet consults before offering the choice
    /// (capability degradation): vercel needs npx, github needs gh ≥
    /// 2.90.0 + the `gh skill` surface.
    public var capabilityGate: CapabilityGate {
        switch self {
        case .vercel: .needsNode
        case .github: .needsGitHub
        }
    }
}

/// Why an installer choice is unavailable in this environment — the
/// install-sheet mirror of AppState.RepairBlock, in core so it is testable.
public enum CapabilityGate: Equatable, Sendable {
    case needsNode
    case needsGitHub
}

/// The install target scope: the global user store
/// (`npx -g` / `gh --scope user`) or one project root (`npx -p` /
/// `gh --scope project`, cwd = root).
public enum InstallTarget: Equatable, Hashable, Sendable {
    case user
    case project(root: String)

    /// The ownership-bucket workspace id the batch's finding ref names, so
    /// the executor's snapshot/diff/rollback cover exactly this surface.
    public var workspaceID: String {
        switch self {
        case .user:
            return "user"
        case .project(let root):
            return "project:\(root)"
        }
    }
}

/// A refusal to build an install batch (mis-formed source, empty skill
/// name, missing gh agent). Named problems, surfaced inline.
public enum InstallPlanError: Error, Equatable, Sendable {
    case missingRepo
    case malformedRepo(String)
    case emptySkillName
    case noSkillsSelected
    case missingGHAgent
    /// gh's write to the Vercel global lock is withheld for this skill
    /// (`CommandBatchBuilder.githubWriteBlocker`).
    case githubWriteWithheld(skill: String, blocker: LifecycleBlocker)

    /// Human-readable refusal (English by design, like other core refusals).
    public var message: String {
        switch self {
        case .missingRepo:
            return "this search result has no installable source (owner/repo)"
        case .malformedRepo(let repo):
            return "source '\(repo)' is not an owner/repo slug; only GitHub-hosted "
                + "skills can be installed by either official installer"
        case .emptySkillName:
            return "the skill name is empty; an install batch cannot be derived"
        case .noSkillsSelected:
            return "no skills are selected; pick at least one skill to install"
        case .missingGHAgent:
            return "a gh install needs a target agent (--agent); pick a host before "
                + "building the batch"
        case .githubWriteWithheld(let skill, let blocker):
            return "cannot install '\(skill)' with gh skill: \(blocker.message)"
        }
    }
}

/// The installer-specific choices of an install, beyond source and target.
public struct InstallOptions: Equatable, Sendable {
    /// Vercel hosts to link the skills into (`-a`, repeatable). Empty keeps
    /// the CLI's own default placement.
    public var vercelAgents: [String]
    /// The gh target agent (`--agent`); required for gh installs.
    public var ghAgent: String?
    /// The optional gh `--pin` ref.
    public var ghPinRef: String?
    /// Install Vercel skills as standalone copies instead of links into the
    /// shared skills folder (`--copy`).
    public var copy: Bool

    public init(
        vercelAgents: [String] = [], ghAgent: String? = nil, ghPinRef: String? = nil,
        copy: Bool = false
    ) {
        self.vercelAgents = vercelAgents
        self.ghAgent = ghAgent
        self.ghPinRef = ghPinRef
        self.copy = copy
    }
}

/// Builds a reviewable install `CommandBatch` from a search result or from
/// skills an installer listed in a repository.
///
/// The batch reuses the exact repair safety model: same `CommandBatch` value
/// (snapshot → per-command review → execute → post-run diff → one-click
/// rollback). Its `findingRefs` carry a synthetic `new-install` ref per
/// skill naming the target ownership bucket so the executor's affected
/// scope, ledger snapshot, and rollback sweep cover precisely the workspace
/// the install touches.
///
/// Command shapes are probe-verified against the CLIs (skills@1.7.0 and
/// gh 2.102.0):
/// - vercel user scope:  `npx skills add <owner/repo> -s <name>… [-a <host>…]
///   [--copy] -g -y` (one command for every selected skill)
/// - vercel project:     same with `-p` (cwd = project root)
/// - github user scope:  `gh skill install <owner/repo> <name> --agent <agent>
///   --scope user -f [--pin <ref>]` (one command per skill; gh takes one
///   skill name per install)
/// - github project:     same with `--scope project` (cwd = project root)
public struct InstallPlanBuilder: Sendable {
    /// The current scan, which guards gh installs against Vercel global lock
    /// writes (`CommandBatchBuilder.githubWriteBlocker`); nil skips the guard.
    let report: ScanReport?

    public init(report: ScanReport? = nil) {
        self.report = report
    }

    /// Builds the proposed batch for one search result. Throws
    /// `InstallPlanError` for results from which no honest batch can be
    /// derived.
    public func build(
        result: SkillSearchResult,
        installer: InstallerChoice,
        target: InstallTarget,
        options: InstallOptions = InstallOptions()
    ) throws -> CommandBatch {
        guard !result.name.isEmpty else {
            throw InstallPlanError.emptySkillName
        }
        guard let repo = result.repo else {
            throw InstallPlanError.missingRepo
        }
        return try build(
            repo: repo, skills: [result.name], installer: installer, target: target,
            options: options)
    }

    /// Withholds a gh install whose write to the Vercel global lock would
    /// lose data (`CommandBatchBuilder.githubWriteBlocker`); a nil report
    /// skips the guard.
    private func guardGitHubWrites(_ skills: [String]) throws {
        guard let report else { return }
        for skill in skills {
            let blocker = CommandBatchBuilder.githubWriteBlocker(skillName: skill, report: report)
            if let blocker {
                throw InstallPlanError.githubWriteWithheld(skill: skill, blocker: blocker)
            }
        }
    }

    /// Builds the proposed batch (status `proposed`, no snapshot) installing
    /// `skills`, named as `installer` listed them, from `repo`.
    public func build(
        repo: String,
        skills: [String],
        installer: InstallerChoice,
        target: InstallTarget,
        options: InstallOptions = InstallOptions()
    ) throws -> CommandBatch {
        guard Self.isOwnerRepo(repo) else {
            throw InstallPlanError.malformedRepo(repo)
        }
        guard !skills.isEmpty else {
            throw InstallPlanError.noSkillsSelected
        }
        guard !skills.contains(where: \.isEmpty) else {
            throw InstallPlanError.emptySkillName
        }
        let commands: [BatchCommand]
        switch installer {
        case .vercel:
            commands = [
                BatchCommandFactory.vercelAdd(
                    repo: repo,
                    skills: skills,
                    agents: options.vercelAgents,
                    target: target,
                    copy: options.copy)
            ]
        case .github:
            guard let agent = options.ghAgent, !agent.isEmpty else {
                throw InstallPlanError.missingGHAgent
            }
            try guardGitHubWrites(skills)
            commands = skills.map { skill in
                BatchCommandFactory.githubInstallNew(
                    repo: repo,
                    skill: skill,
                    agent: agent,
                    target: target,
                    pinRef: options.ghPinRef)
            }
        }
        let id = "install-\(UUID().uuidString)"
        let workspaceID = target.workspaceID
        return CommandBatch(
            id: id,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            findingRefs: skills.map { skill in
                FindingRef(
                    findingID: id,
                    ruleID: "new-install",
                    skillName: skill,
                    workspaceID: workspaceID)
            },
            // Installs are not finding-fix decisions: the decisions vocabulary
            // (update/adopt/cleanup/leave/arbitrate) stays sealed, and the
            // executor + snapshot/diff/rollback pipeline read only the
            // finding refs for affected-scope derivation.
            decisions: [],
            commands: commands,
            snapshotID: nil,
            status: .proposed)
    }

    /// The owner/repo slug of a typed source: `owner/repo` or a github.com
    /// repository URL (HTTPS or SSH, with or without `.git` or a trailing
    /// slash). Anything else is refused as `malformedRepo`.
    public static func ownerRepo(fromSource source: String) throws -> String {
        var trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        let repo = BatchCommandFactory.ownerRepo(from: trimmed)
        guard isOwnerRepo(repo) else {
            throw InstallPlanError.malformedRepo(trimmed)
        }
        return repo
    }

    /// An owner/repo slug: exactly two non-empty `/`-separated components of
    /// GitHub-safe characters. Both official installers accept this shape.
    static func isOwnerRepo(_ repo: String) -> Bool {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return false
        }
        return parts.allSatisfy { part in
            part.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        }
    }
}
