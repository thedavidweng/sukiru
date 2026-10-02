import Foundation

/// Constructors for every command shape a batch may contain.
///
/// Ledger writes are only official CLI invocations — `npx skills …` (vercel
/// ledger) and `gh skill …` (github ledger). Flagged direct file operations
/// cover what no CLI can (ownerless payloads here; placement fixes in
/// BatchCommandFactory+FileOps.swift).
enum BatchCommandFactory {
    // MARK: - npx skills (vercel ledger)

    /// `npx skills update <name>… (-p|-g) -y` — the plain vercel update; the
    /// CLI takes several names in one run. NEVER used for drift repair.
    /// Project-scope commands carry the project root as `workingDirectory`
    /// (npx resolves `-p` literally from cwd). `reason` names what asked
    /// for the update (a finding, or the Library).
    static func vercelUpdate(
        names: [String], scope: Scope, reason: String, workingDirectory: String? = nil
    ) -> BatchCommand {
        let argv = ["npx", "skills", "update"] + names + [scope == .user ? "-g" : "-p", "-y"]
        return BatchCommand(
            argv: argv,
            displayString: BatchCommand.display(for: argv),
            owningCLI: .vercel,
            intent: "Update \(quoted(names)) through the Vercel CLI (\(reason)): "
                + "refresh the ledger-owned copies.",
            dangerFlags: [],
            warning: nil,
            workingDirectory: workingDirectory
        )
    }

    /// `npx skills add <recorded source> --skill <name> [-a <host>…] [--copy] [-g] -y` —
    /// re-install from the vercel lock's recorded source. This is BOTH the
    /// drift repair (`npx skills update` reports "already up to date"
    /// while ignoring drifted copies) and the keep-vercel arbitration
    /// (proven side effect: it erases gh frontmatter provenance).
    ///
    /// Probe-verified against skills@1.5.26: an UNTARGETED
    /// `add` refreshes only the canonical `.agents/skills` copy and leaves
    /// drifted or gh-overwritten copies in other host dirs (and their
    /// provenance) untouched, so the planner passes every placement's host
    /// in `agents`; `copy` is set when a physical (non-symlink) copy lives
    /// outside the canonical store so the re-install refreshes in copy mode.
    static func vercelReinstall(
        name: String,
        source: String,
        scope: Scope,
        agents: [String] = [],
        copy: Bool = false,
        intent: String,
        consequence: CommandConsequence,
        workingDirectory: String? = nil
    ) -> BatchCommand {
        var argv = ["npx", "skills", "add", source, "--skill", name]
        for agent in agents {
            argv += ["-a", agent]
        }
        if copy {
            argv.append("--copy")
        }
        if scope == .user {
            argv.append("-g")
        }
        argv.append("-y")
        return BatchCommand(
            argv: argv,
            displayString: BatchCommand.display(for: argv),
            owningCLI: .vercel,
            intent: intent,
            dangerFlags: [],
            warning: nil,
            consequence: consequence,
            workingDirectory: workingDirectory
        )
    }

    /// `npx skills remove <name> [-g] -y` — name-based, ledger-blind deletion
    /// (collision-matrix scenario 6). ALWAYS carries the dangerous-deletion
    /// flag and warning, naming detectable at-risk
    /// cross-ledger skills.
    static func vercelRemove(
        name: String,
        scope: Scope,
        atRisk: [AtRiskSkill],
        intent: String,
        consequence: CommandConsequence? = nil,
        workingDirectory: String? = nil
    ) -> BatchCommand {
        var argv = ["npx", "skills", "remove", name]
        if scope == .user {
            argv.append("-g")
        }
        argv.append("-y")
        return BatchCommand(
            argv: argv,
            displayString: BatchCommand.display(for: argv),
            owningCLI: .vercel,
            intent: intent,
            dangerFlags: [.dangerousDeletion],
            warning: dangerousDeletionWarning(name: name, atRisk: atRisk),
            atRiskSkills: atRisk,
            consequence: consequence,
            workingDirectory: workingDirectory
        )
    }

    /// The skills a name-based `npx skills remove` of `skill` endangers:
    /// none when the Vercel ledger alone claims the name in its scope,
    /// otherwise the skill itself under its other claim.
    static func removalAtRisk(_ skill: Skill) -> [AtRiskSkill] {
        skill.ownership == .vercel
            ? [] : [AtRiskSkill(skill: skill.name, ownership: skill.ownership.rawValue)]
    }

    /// The dangerous-deletion warning prose: removal is
    /// by name across ownership, and detectable at-risk skills are named with
    /// their owning ledger.
    static func dangerousDeletionWarning(name: String, atRisk: [AtRiskSkill]) -> String {
        var warning = "Dangerous deletion: npx skills remove deletes by name across ownership"
        warning += ", so it can delete skills belonging to the other ledger or to no ledger."
        if atRisk.isEmpty {
            warning += " No cross-ledger skills named '\(name)' were detected in this scope."
            return warning
        }
        let named = atRisk.map { "\($0.skill) (\($0.ownership))" }.joined(separator: ", ")
        warning += " At risk in this scope: \(named)."
        return warning
    }

    // MARK: - gh skill (github ledger)

    /// `gh skill update <name>… --dir <dir>` for one skills dir — the
    /// narrowest targeting available (named skills + `--dir`, never a
    /// bare `--all`); callers emit one per distinct placement dir.
    static func githubUpdate(names: [String], dir: String, reason: String) -> BatchCommand {
        let argv = ["gh", "skill", "update"] + names + ["--dir", dir]
        return BatchCommand(
            argv: argv,
            displayString: BatchCommand.display(for: argv),
            owningCLI: .github,
            intent: "Update \(quoted(names)) through the GitHub CLI (\(reason)): "
                + "gh skill update, narrowly scoped to \(dir).",
            dangerFlags: [],
            warning: nil
        )
    }

    private static func quoted(_ names: [String]) -> String {
        names.map { "'\($0)'" }.joined(separator: ", ")
    }

    /// `gh skill install <owner/repo> <path> --force --dir <dir>` — the
    /// verified non-interactive re-anchoring shape, used for ownerless
    /// adoption and the keep-github arbitration.
    static func githubInstall(
        repo: String,
        path: String,
        dir: String,
        intent: String,
        consequence: CommandConsequence
    ) -> BatchCommand {
        let argv = ["gh", "skill", "install", repo, path, "--force", "--dir", dir]
        return BatchCommand(
            argv: argv,
            displayString: BatchCommand.display(for: argv),
            owningCLI: .github,
            intent: intent,
            dangerFlags: [],
            warning: nil,
            consequence: consequence
        )
    }

    // MARK: - ownerless direct file operations

    /// Flagged direct deletion of an ownerless skill's directory placements:
    /// no CLI owns the skill, so cleanup is a file
    /// operation — explicitly flagged, and always snapshotted before
    /// execution by the batch pipeline.
    static func ownerlessCleanups(
        name: String, paths: [String], finding: Finding
    ) -> [BatchCommand] {
        paths.map { path in
            let argv = FileOperation.deleteDirectory(path).argv
            return BatchCommand(
                argv: argv,
                displayString: "delete directory "
                    + BatchCommand.display(for: [path])
                    + " (direct file operation; ownerless skill cleanup)",
                owningCLI: .file,
                intent: "Clean up ownerless skill '\(name)' (finding \(finding.ruleID)): "
                    + "delete \(path) directly, since no official CLI manages this skill.",
                dangerFlags: [.directFileOperation, .ownerlessCleanup],
                warning: "Direct file deletion of ownerless skill '\(name)': no CLI owns "
                    + "this skill. The full payload is captured in the batch snapshot "
                    + "before deletion."
            )
        }
    }

    // MARK: - new installs

    /// `npx skills add <owner/repo> -s <name> [--copy] (-g|-p) -y` — the verified
    /// non-interactive NEW-install shape (probe-verified 2026-09-18 against
    /// skills@1.5.x: `-y` runs with zero prompts; `-g`/`-p` pin the scope
    /// explicitly, never relying on cwd auto-detection). Project scope
    /// carries the root as `workingDirectory` (npx resolves `-p` from cwd).
    static func vercelAdd(
        repo: String,
        skill: String,
        target: InstallTarget,
        copy: Bool = false
    ) -> BatchCommand {
        var argv = ["npx", "skills", "add", repo, "-s", skill]
        if copy {
            argv.append("--copy")
        }
        let projectRoot: String?
        switch target {
        case .user:
            argv.append("-g")
            projectRoot = nil
        case .project(let root):
            argv.append("-p")
            projectRoot = root
        }
        argv.append("-y")
        return BatchCommand(
            argv: argv,
            displayString: BatchCommand.display(for: argv),
            owningCLI: .vercel,
            intent: "Install new skill '\(skill)' from \(repo) into the Vercel ledger"
                + " (installer choice: npx skills add).",
            dangerFlags: [],
            warning: nil,
            consequence: .entersVercelLedger,
            workingDirectory: projectRoot
        )
    }

    /// `gh skill install <owner/repo> <name> --agent <agent> --scope user|project
    /// [-f] [--pin <ref>]` — the verified non-interactive NEW-install shape
    /// (probe-verified 2026-09-18 against gh 2.90+: `--agent` + `--scope`
    /// select the placement, `-f` skips overwrite prompts). Project scope
    /// carries the root as `workingDirectory` (gh resolves the repo from
    /// cwd).
    static func githubInstallNew(
        repo: String,
        skill: String,
        agent: String,
        target: InstallTarget,
        pinRef: String?
    ) -> BatchCommand {
        var argv = ["gh", "skill", "install", repo, skill, "--agent", agent]
        let projectRoot: String?
        switch target {
        case .user:
            argv.append("--scope")
            argv.append("user")
            projectRoot = nil
        case .project(let root):
            argv.append("--scope")
            argv.append("project")
            projectRoot = root
        }
        argv.append("-f")
        if let pinRef, !pinRef.isEmpty {
            argv.append("--pin")
            argv.append(pinRef)
        }
        return BatchCommand(
            argv: argv,
            displayString: BatchCommand.display(for: argv),
            owningCLI: .github,
            intent: "Install new skill '\(skill)' from \(repo) into the GitHub ledger"
                + " (installer choice: gh skill install, agent \(agent)).",
            dangerFlags: [],
            warning: nil,
            consequence: .writesGitHubProvenance(agent: agent, pinRef: pinRef),
            workingDirectory: projectRoot
        )
    }

    // MARK: - recorded-repo normalization

    /// The gh ledger records `github-repo` as a full URL (no `.git`);
    /// `gh skill install` wants `owner/repo`. Standard github.com URL forms
    /// are normalized; anything else passes through verbatim.
    static func ownerRepo(from recordedRepo: String) -> String {
        var repo = recordedRepo
        let prefixes = ["https://github.com/", "http://github.com/", "git@github.com:"]
        for prefix in prefixes where repo.hasPrefix(prefix) {
            repo = String(repo.dropFirst(prefix.count))
        }
        if repo.hasSuffix(".git") {
            repo = String(repo.dropLast(4))
        }
        return repo
    }
}
