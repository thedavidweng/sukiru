import Foundation

/// Constructors for every command shape a batch may contain
/// (architecture §4.1 repair side, D10/D11/D13/D22).
///
/// Only official CLI invocations are produced here — `npx skills …` (vercel
/// ledger) and `gh skill …` (github ledger) — plus the single permitted
/// exception: flagged direct file operations on ownerless skills.
enum BatchCommandFactory {
    // MARK: - npx skills (vercel ledger)

    /// `npx skills update <name> (-p|-g) -y` — the plain vercel update
    /// (VAL-REPAIR-009). NEVER used for drift repair (D22). Project-scope
    /// commands carry the project root as `workingDirectory` (npx resolves
    /// `-p` literally from cwd).
    static func vercelUpdate(
        name: String, scope: Scope, finding: Finding, workingDirectory: String? = nil
    ) -> BatchCommand {
        let argv = ["npx", "skills", "update", name, scope == .user ? "-g" : "-p", "-y"]
        return BatchCommand(
            argv: argv,
            displayString: BatchCommand.display(for: argv),
            owningCLI: .vercel,
            intent: "Update '\(name)' through the Vercel CLI (finding \(finding.ruleID)): "
                + "refresh the ledger-owned copies of the skill.",
            dangerFlags: [],
            warning: nil,
            workingDirectory: workingDirectory
        )
    }

    /// `npx skills add <recorded source> --skill <name> [-a <host>…] [--copy] [-g] -y` —
    /// re-install from the vercel lock's recorded source. This is BOTH the
    /// D22 drift repair (`npx skills update` reports "already up to date"
    /// while ignoring drifted copies) and the D10 keep-vercel arbitration
    /// (proven side effect: it erases gh frontmatter provenance).
    ///
    /// Probe-verified against skills@1.5.26 (seam-b-e2e): an UNTARGETED
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
        consequence: String,
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
    /// flag and warning (VAL-REPAIR-020), naming detectable at-risk
    /// cross-ledger skills (VAL-REPAIR-021).
    static func vercelRemove(
        name: String,
        scope: Scope,
        finding: Finding,
        atRisk: [AtRiskSkill],
        intent: String,
        consequence: String? = nil,
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

    /// The dangerous-deletion warning prose (VAL-REPAIR-020/021): removal is
    /// by name across ownership, and detectable at-risk skills are named with
    /// their owning ledger.
    static func dangerousDeletionWarning(name: String, atRisk: [AtRiskSkill]) -> String {
        var warning = "Dangerous deletion: npx skills remove deletes by name across ownership"
        warning += " — it can delete skills belonging to the other ledger or to no ledger."
        if atRisk.isEmpty {
            warning += " No cross-ledger skills named '\(name)' were detected in this scope."
            return warning
        }
        let named = atRisk.map { "\($0.skill) (\($0.ownership))" }.joined(separator: ", ")
        warning += " At risk in this scope: \(named)."
        return warning
    }

    // MARK: - gh skill (github ledger)

    /// `gh skill update <name> --dir <dir>` per placement directory — the
    /// narrowest targeting available (D13: named skill + `--dir`, never a
    /// bare `--all`), one command per distinct skills dir (VAL-REPAIR-010).
    static func githubUpdates(name: String, dirs: [String], finding: Finding) -> [BatchCommand] {
        dirs.map { dir in
            let argv = ["gh", "skill", "update", name, "--dir", dir]
            return BatchCommand(
                argv: argv,
                displayString: BatchCommand.display(for: argv),
                owningCLI: .github,
                intent: "Update '\(name)' through the GitHub CLI (finding \(finding.ruleID)): "
                    + "gh skill update, narrowly scoped to \(dir).",
                dangerFlags: [],
                warning: nil
            )
        }
    }

    /// `gh skill install <owner/repo> <path> --force --dir <dir>` — the
    /// verified non-interactive re-anchoring shape, used for ownerless
    /// adoption (D11) and the D10 keep-github arbitration.
    static func githubInstall(
        repo: String,
        path: String,
        dir: String,
        intent: String,
        consequence: String
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

    // MARK: - ownerless direct file operations (the ONLY permitted kind)

    /// Flagged direct deletion of an ownerless skill's directory placements
    /// (VAL-REPAIR-018): no CLI owns the skill, so cleanup is a file
    /// operation — explicitly flagged, and always snapshotted before
    /// execution by the batch pipeline.
    static func ownerlessCleanups(
        name: String, paths: [String], finding: Finding
    ) -> [BatchCommand] {
        paths.map { path in
            let argv = ["sukiru-fileop", "delete-directory", path]
            return BatchCommand(
                argv: argv,
                displayString: "delete directory "
                    + BatchCommand.display(for: [path])
                    + " (direct file operation; ownerless skill cleanup)",
                owningCLI: .file,
                intent: "Clean up ownerless skill '\(name)' (finding \(finding.ruleID)): "
                    + "delete \(path) directly — no official CLI manages this skill.",
                dangerFlags: [.directFileOperation, .ownerlessCleanup],
                warning: "Direct file deletion of ownerless skill '\(name)': no CLI owns "
                    + "this skill. The full payload is captured in the batch snapshot "
                    + "before deletion."
            )
        }
    }

    // MARK: - new installs (stories 22–24)

    /// `npx skills add <owner/repo> -s <name> (-g|-p) -y` — the verified
    /// non-interactive NEW-install shape (probe-verified 2026-09-18 against
    /// skills@1.5.x: `-y` runs with zero prompts; `-g`/`-p` pin the scope
    /// explicitly, never relying on cwd auto-detection). Project scope
    /// carries the root as `workingDirectory` (npx resolves `-p` from cwd).
    static func vercelAdd(
        repo: String,
        skill: String,
        target: InstallTarget
    ) -> BatchCommand {
        var argv = ["npx", "skills", "add", repo, "-s", skill]
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
            consequence:
                "Installing with npx skills enters the skill into the Vercel lockfile"
                + " ledger: the canonical copy lands in .agents/skills and host "
                + "placements follow the CLI's default agent coverage.",
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
            consequence:
                "Installing with gh writes GitHub provenance into the skill's "
                + "frontmatter (metadata.github-*): GitHub-only sources, installed "
                + "for agent \(agent)."
                + (pinRef.flatMap { !$0.isEmpty ? " Pinned to \($0)." : nil } ?? ""),
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
