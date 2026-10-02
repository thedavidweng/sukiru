import Foundation

/// A newer upstream version `gh skill update --dry-run` reports for one
/// installed skill.
public struct GitHubUpdate: Equatable, Sendable {
    /// The skill's local tree SHA when the check ran, so a result can be
    /// recognized as stale once the skill changes on disk.
    public let installedTreeSha: String?
    /// The upstream tree SHA, abbreviated as gh prints it.
    public let availableTree: String
    /// The ref gh resolved upstream (`main`, a tag).
    public let ref: String?

    public init(installedTreeSha: String?, availableTree: String, ref: String?) {
        self.installedTreeSha = installedTreeSha
        self.availableTree = availableTree
        self.ref = ref
    }
}

/// One skill the check found an update for.
public struct SkillUpdate: Equatable, Sendable {
    public let skill: Skill
    public let update: GitHubUpdate
}

/// The outcome of checking a set of skills: the updates found, and the gh
/// diagnostics of every skills folder that could not be checked.
public struct GitHubUpdateCheck: Equatable, Sendable {
    public let updates: [SkillUpdate]
    public let failures: [String]
}

/// Checks GitHub-ledger skills for upstream updates by asking gh itself
/// (ADR-0004: Sukiru builds no updater of its own).
///
/// `gh skill update --dry-run <name>… --dir <dir>` is read-only
/// (probe-verified against gh 2.102.0: no file changes, the Vercel global
/// lock included). With `--dir`, gh scans only that folder and skips
/// symlinked entries. Pinned skills are skipped by gh with a notice.
public struct GitHubUpdateChecker: Sendable {
    /// One dry-run resolves the ref and walks the tree of every repository.
    static let timeout: TimeInterval = 180

    private let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    public init(environment: SukiruEnvironment) {
        self.init(runner: SystemCommandRunner(environment: environment, timeout: Self.timeout))
    }

    /// The skills gh can check: GitHub-ledger, non-ambiguous, with at least
    /// one directory placement.
    public static func checkable(_ skills: [Skill]) -> [Skill] {
        skills.filter {
            $0.ownership == .github && !$0.ambiguous
                && $0.placements.contains { $0.kind == .directory }
        }
    }

    /// Runs one dry-run per skills folder and maps the reported updates back
    /// to the skills.
    public func check(_ skills: [Skill]) -> GitHubUpdateCheck {
        var namesByDir: [String: Set<String>] = [:]
        for skill in Self.checkable(skills) {
            for dir in Self.directoryParents(of: skill) {
                namesByDir[dir, default: []].insert(skill.name)
            }
        }
        var reported: [String: (tree: String, ref: String?)] = [:]
        var failures: [String] = []
        for dir in namesByDir.keys.sorted() {
            let names = (namesByDir[dir] ?? []).sorted()
            guard let outcome = runner.run("gh", Self.arguments(names: names, dir: dir)) else {
                failures.append("\(dir): gh could not be started or timed out")
                continue
            }
            guard outcome.exitCode == 0 else {
                let diagnostic = RepositorySkillLister.diagnostic(outcome, installer: .github)
                failures.append("\(dir): \(diagnostic)")
                continue
            }
            for line in Self.parseDryRun(outcome.stdout) {
                reported[dir + "/" + line.name] = (line.tree, line.ref)
            }
        }
        let updates = Self.checkable(skills).compactMap { skill -> SkillUpdate? in
            let hit = Self.directoryParents(of: skill).lazy
                .compactMap { reported[$0 + "/" + skill.name] }.first
            return hit.map {
                SkillUpdate(
                    skill: skill,
                    update: GitHubUpdate(
                        installedTreeSha: skill.provenance.github?.treeSha,
                        availableTree: $0.tree, ref: $0.ref))
            }
        }
        return GitHubUpdateCheck(updates: updates, failures: failures)
    }

    static func arguments(names: [String], dir: String) -> [String] {
        ["skill", "update", "--dry-run"] + names + ["--dir", dir]
    }

    private static func directoryParents(of skill: Skill) -> [String] {
        let dirs = skill.placements.filter { $0.kind == .directory }.map {
            CommandBatchBuilder.parentDir($0.path)
        }
        return Array(Set(dirs)).sorted()
    }

    /// One update row of the dry-run listing.
    struct ListedUpdate: Equatable {
        let name: String
        let tree: String
        let ref: String?
    }

    /// Parses the dry-run's stdout rows (gh 2.102.0, piped):
    /// `  • <name> (<owner>/<repo>) <old> > <new> [<ref>]`, or
    /// `  • <name> (<owner>/<repo>) <new> (reinstall) [<ref>]` under
    /// `--force`. Notices and the summary go to stderr and are ignored.
    static func parseDryRun(_ output: String) -> [ListedUpdate] {
        let row =
            #/^\s*[•*]\s+(?<name>\S+)\s+\([^)]*\)\s+(?<change>.*?)\s*(?:\[(?<ref>[^\]]*)\])?\s*$/#
        return output.components(separatedBy: "\n").compactMap { line in
            let plain = line.replacingOccurrences(
                of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            guard let match = plain.wholeMatch(of: row) else { return nil }
            let change = String(match.output.change)
            let tree: Substring
            if let arrow = change.range(of: ">") {
                tree = change[arrow.upperBound...]
            } else if let reinstall = change.range(of: "(reinstall)") {
                tree = change[..<reinstall.lowerBound]
            } else {
                return nil
            }
            let trimmed = tree.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let ref = match.output.ref.map(String.init)
            return ListedUpdate(
                name: String(match.output.name), tree: trimmed,
                ref: ref?.isEmpty == false ? ref : nil)
        }
    }
}
