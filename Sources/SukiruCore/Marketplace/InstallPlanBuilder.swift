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
    case missingGHAgent

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
        case .missingGHAgent:
            return "a gh install needs a target agent (--agent); pick a host before "
                + "building the batch"
        }
    }
}

/// Builds a reviewable install `CommandBatch` from one search result.
///
/// The batch reuses the exact repair safety model: same `CommandBatch` value
/// (snapshot → per-command review → execute → post-run diff → one-click
/// rollback). Its `findingRefs` carry a synthetic `new-install` ref naming
/// the target ownership bucket so the executor's affected scope, ledger
/// snapshot, and rollback sweep cover precisely the workspace the install
/// touches.
///
/// Command shapes are probe-verified against the pinned CLIs
/// (skills@1.5.9+ and gh 2.90+):
/// - vercel user scope:  `npx skills add <owner/repo> -s <name> [--copy] -g -y`
/// - vercel project:     `npx skills add <owner/repo> -s <name> -p -y`
///   (cwd = project root)
/// - github user scope:  `gh skill install <owner/repo> <name> --agent <agent>
///   --scope user  [-f] [--pin <ref>]`
/// - github project:     same with `--scope project` (cwd = project root)
public struct InstallPlanBuilder: Sendable {
    public init() {}

    /// Builds the proposed batch (status `proposed`, no snapshot) from the
    /// search result + installer + target. Throws `InstallPlanError` for
    /// sources/choices from which no honest batch can be derived. `copy`
    /// installs Vercel skills as standalone copies instead of links into the
    /// shared skills folder.
    public func build(
        result: SkillSearchResult,
        installer: InstallerChoice,
        target: InstallTarget,
        ghAgent: String? = nil,
        ghPinRef: String? = nil,
        copy: Bool = false
    ) throws -> CommandBatch {
        guard !result.name.isEmpty else {
            throw InstallPlanError.emptySkillName
        }
        guard let repo = result.repo else {
            throw InstallPlanError.missingRepo
        }
        guard Self.isOwnerRepo(repo) else {
            throw InstallPlanError.malformedRepo(repo)
        }
        let command: BatchCommand
        switch installer {
        case .vercel:
            command = BatchCommandFactory.vercelAdd(
                repo: repo,
                skill: result.name,
                target: target,
                copy: copy)
        case .github:
            guard let agent = ghAgent, !agent.isEmpty else {
                throw InstallPlanError.missingGHAgent
            }
            command = BatchCommandFactory.githubInstallNew(
                repo: repo,
                skill: result.name,
                agent: agent,
                target: target,
                pinRef: ghPinRef)
        }
        let id = "install-\(UUID().uuidString)"
        let workspaceID = target.workspaceID
        return CommandBatch(
            id: id,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            findingRefs: [
                FindingRef(
                    findingID: id,
                    ruleID: "new-install",
                    skillName: result.name,
                    workspaceID: workspaceID)
            ],
            // Installs are not finding-fix decisions: the decisions vocabulary
            // (update/adopt/cleanup/leave/arbitrate) stays sealed, and the
            // executor + snapshot/diff/rollback pipeline read only the
            // finding refs for affected-scope derivation.
            decisions: [],
            commands: [command],
            snapshotID: nil,
            status: .proposed)
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
