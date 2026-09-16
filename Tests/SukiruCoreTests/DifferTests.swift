import Foundation
import Testing

@testable import SukiruCore

/// The post-run Differ (architecture §4.1 + D9): rescan of the affected
/// roots diffed against the pre-run scan and the snapshot — placements
/// added/removed/changed, file-level changes inside snapshotted payloads,
/// ledger byte changes, and lock-entry deltas. An untouched tree yields an
/// explicitly empty diff (VAL-REPAIR-032/033).
@Suite("Differ")
struct DifferTests {
    private typealias Support = SnapshotTestSupport

    /// The Differ's environment: SUKIRU_HOME + the sandbox project root.
    private static func environment(home: String, project: String) -> SukiruEnvironment {
        SukiruEnvironment(
            reader: DictionaryEnvironmentReader(
                ["SUKIRU_HOME": home, "SUKIRU_ROOTS": project]))
    }

    /// "kind|path" strings for set-equality assertions.
    private static func keys(_ diff: BatchDiff) -> Set<String> {
        Set(diff.entries.map { $0.kind.rawValue + "|" + $0.path })
    }

    @Test("An untouched tree diffs empty — explicitly, not by omission")
    func emptyDiffIsExplicit() throws {
        let tree = try Support.makeTree()
        let store = Support.makeStore(home: tree.home.path)
        let refs = Support.userAndProjectRefs(project: tree.project)
        let manifest = try store.capture(batch: Support.batch(refs: refs), report: tree.report)
        let post = try OwnershipBuilders.scan(home: tree.home, projectRoots: [tree.project])
        let differ = Differ(
            environment: Self.environment(home: tree.home.path, project: tree.project.path))
        let diff = differ.diff(
            touchedWorkspaceIDs: ["user", "project:\(tree.project.path)"],
            pre: tree.report, post: post, manifest: manifest)
        #expect(diff.entries.isEmpty)
        #expect(diff.isEmpty)
        let summary = try #require(diff.summary.only)
        #expect(summary.localizedCaseInsensitiveContains("no change"))
        // Round-trips through the deterministic JSON encoding.
        let decoded = try JSONDecoder().decode(BatchDiff.self, from: diff.jsonData())
        #expect(decoded == diff)
    }

    @Test("Placement, file, symlink, and lock-entry changes are each reported precisely")
    func placementFileAndLockChanges() throws {
        let tree = try Support.makeTree()
        let store = Support.makeStore(home: tree.home.path)
        let refs = Support.userAndProjectRefs(project: tree.project)
        let manifest = try store.capture(batch: Support.batch(refs: refs), report: tree.report)
        let home = tree.home.path
        let project = tree.project.path
        let tool = project + "/.claude/skills/tool"
        try Self.mutateEveryChannel(home: home, project: project, tree: tree)

        let post = try OwnershipBuilders.scan(home: tree.home, projectRoots: [tree.project])
        let differ = Differ(environment: Self.environment(home: home, project: project))
        let diff = differ.diff(
            touchedWorkspaceIDs: ["user", "project:\(project)"],
            pre: tree.report, post: post, manifest: manifest)

        // The alias symlink at .claude/skills/orphan is NOT an entry: a
        // symlink's on-disk identity is its target string, which did not
        // change (its content hash follows the canonical dir, reported
        // there — no double-reporting).
        // swift-format requires the trailing comma swiftlint forbids in
        // multi-line collection literals — suppressed for this expectation.
        // swiftlint:disable trailing_comma
        let expected: Set<String> = [
            "placement-added|" + home + "/.claude/skills/newbie",
            "placement-changed|" + home + "/.agents/skills/orphan",
            "placement-changed|" + tool,
            "file-changed|" + home + "/.agents/skills/orphan/latest",
            "file-added|" + tool + "/extra.py",
            "file-changed|" + tool + "/notes.md",
            "file-changed|" + project + "/skills-lock.json",
            "lock-entry-added|" + project + "/skills-lock.json",
            "lock-entry-changed|" + project + "/skills-lock.json",
        ]
        // swiftlint:enable trailing_comma
        #expect(Self.keys(diff) == expected)
        let added = try #require(diff.entries.first { $0.kind == .lockEntryAdded })
        #expect(added.detail.contains("newskill"))
        let changed = try #require(diff.entries.first { $0.kind == .lockEntryChanged })
        #expect(changed.detail.contains("tool"))
        #expect(changed.detail.contains("computedHash"))
        let hashChange = try #require(diff.entries.first { $0.path == tool })
        #expect(hashChange.detail.contains("content hash"))
        // The summary is the human-readable rendering: one line per entry.
        #expect(diff.summary.count == diff.entries.count)
        #expect(!diff.isEmpty)
    }

    /// One mutation through every diff channel: a changed file and an added
    /// file inside a payload placement, a retargeted symlink inside another
    /// payload, a new placement in a watched dir, and a lock rewrite that
    /// changes one entry's computedHash and adds a second entry.
    private static func mutateEveryChannel(
        home: String, project: String, tree: SnapshotSandbox
    ) throws {
        let tool = project + "/.claude/skills/tool"
        try "notes v2".write(
            toFile: tool + "/notes.md", atomically: true, encoding: .utf8)
        try "print(1)\n".write(
            toFile: tool + "/extra.py", atomically: true, encoding: .utf8)
        let latest = home + "/.agents/skills/orphan/latest"
        let fileManager = FileManager.default
        try fileManager.removeItem(atPath: latest)
        try fileManager.createSymbolicLink(atPath: latest, withDestinationPath: ".hidden")
        try tree.home.file(
            ".claude/skills/newbie/SKILL.md", contents: OwnershipBuilders.skillMD("newbie"))
        let zeros = String(repeating: "0", count: 64)
        let ones = String(repeating: "1", count: 64)
        let lock = """
            {
              "version": 1,
              "skills": {
                "tool": {
                  "source": "thedavidweng/skills",
                  "sourceType": "github",
                  "skillPath": ".agents/skills/tool/SKILL.md",
                  "computedHash": "\(zeros)"
                },
                "newskill": {
                  "source": "other/repo",
                  "sourceType": "github",
                  "skillPath": ".agents/skills/newskill/SKILL.md",
                  "computedHash": "\(ones)"
                }
              }
            }
            """
        try lock.write(toFile: project + "/skills-lock.json", atomically: true, encoding: .utf8)
    }

    @Test("A deleted placement diffs as placement-removed; its dangling alias degrades")
    func placementRemoval() throws {
        let tree = try Support.makeTree()
        let store = Support.makeStore(home: tree.home.path)
        let refs = [Support.ref("f-orphan", skill: "orphan", workspace: "user")]
        let manifest = try store.capture(batch: Support.batch(refs: refs), report: tree.report)
        let home = tree.home.path
        let orphan = home + "/.agents/skills/orphan"
        try FileManager.default.removeItem(atPath: orphan)
        let post = try OwnershipBuilders.scan(home: tree.home, projectRoots: [tree.project])
        let differ = Differ(
            environment: Self.environment(home: home, project: tree.project.path))
        let diff = differ.diff(
            touchedWorkspaceIDs: ["user"], pre: tree.report, post: post, manifest: manifest)
        let got = Self.keys(diff)
        #expect(got.contains("placement-removed|" + orphan))
        let alias = try #require(
            diff.entries.first { $0.path == home + "/.claude/skills/orphan" })
        #expect(alias.kind == .placementChanged)
        #expect(alias.detail.contains("broken"))
        // The payload vanishing with its placement is covered by the
        // placement-removed entry — no per-file flood for a deleted tree.
        #expect(!got.contains("file-removed|" + orphan))
    }

    @Test("Changes outside the batch's touched scopes never appear in the diff")
    func outOfScopeChangesIgnored() throws {
        let tree = try Support.makeTree()
        let store = Support.makeStore(home: tree.home.path)
        let refs = [Support.ref("f-orphan", skill: "orphan", workspace: "user")]
        let manifest = try store.capture(batch: Support.batch(refs: refs), report: tree.report)
        let project = tree.project.path
        // Mutations confined to the UNTOUCHED project scope.
        try "sneaky".write(
            toFile: project + "/.claude/skills/tool/notes.md", atomically: true, encoding: .utf8)
        try "{}\n".write(
            toFile: project + "/skills-lock.json", atomically: true, encoding: .utf8)
        let post = try OwnershipBuilders.scan(home: tree.home, projectRoots: [tree.project])
        let differ = Differ(
            environment: Self.environment(home: tree.home.path, project: project))
        let diff = differ.diff(
            touchedWorkspaceIDs: ["user"], pre: tree.report, post: post, manifest: manifest)
        #expect(diff.entries.isEmpty)
        #expect(diff.isEmpty)
    }

    @Test("The diff covers exactly the paths an independent recursive comparison finds")
    func diffMatchesIndependentComparison() throws {
        let tree = try Support.makeTree()
        let store = Support.makeStore(home: tree.home.path)
        let refs = Support.userAndProjectRefs(project: tree.project)
        let batch = Support.batch(refs: refs)
        let manifest = try store.capture(batch: batch, report: tree.report)
        let home = tree.home.path
        let project = tree.project.path
        let before = try Self.combinedChecksum(home: home, project: project)

        let tool = project + "/.claude/skills/tool"
        try "notes v2".write(toFile: tool + "/notes.md", atomically: true, encoding: .utf8)
        try "print(1)\n".write(toFile: tool + "/extra.py", atomically: true, encoding: .utf8)
        let deep = home + "/.agents/skills/orphan/scripts/nested/deep.txt"
        try FileManager.default.removeItem(atPath: deep)
        try tree.home.file(
            ".claude/skills/newbie/SKILL.md", contents: OwnershipBuilders.skillMD("newbie"))

        let after = try Self.combinedChecksum(home: home, project: project)
        let changed = Self.changedPaths(before: before, after: after)
        #expect(!changed.isEmpty)

        let post = try OwnershipBuilders.scan(home: tree.home, projectRoots: [tree.project])
        let differ = Differ(environment: Self.environment(home: home, project: project))
        let diff = differ.diff(
            touchedWorkspaceIDs: ["user", "project:\(project)"],
            pre: tree.report, post: post, manifest: manifest)
        let entryPaths = diff.entries.map(\.path)
        // No extra entries: every diff entry is itself a changed path or the
        // placement ancestor of changed paths.
        for path in entryPaths {
            let isAncestor = changed.contains { $0.hasPrefix(path + "/") }
            let covered = changed.contains(path) || isAncestor
            #expect(covered, "diff entry '\(path)' has no independent counterpart")
        }
        // No missing entries: every independently changed path is a diff
        // entry or inside an added/removed placement entry.
        for path in changed {
            let insideEntry = entryPaths.contains { path.hasPrefix($0 + "/") }
            let covered = entryPaths.contains(path) || insideEntry
            #expect(covered, "independent change '\(path)' is missing from the diff")
        }
    }

    // MARK: - independent comparison helpers

    /// TreeChecksum manifests of home (minus the app-support tree the
    /// snapshot lives in) and the project, rebased to absolute paths.
    private static func combinedChecksum(
        home: String, project: String
    ) throws -> [String: String] {
        var combined: [String: String] = [:]
        let homeManifest = try TreeChecksum.manifest(root: home)
        for (relative, value) in homeManifest
        where relative != "." && !relative.hasPrefix("Library") {
            combined[HostPathResolver.join(home, relative)] = value
        }
        let projectManifest = try TreeChecksum.manifest(root: project)
        for (relative, value) in projectManifest where relative != "." {
            combined[HostPathResolver.join(project, relative)] = value
        }
        return combined
    }

    /// Absolute paths whose entry appeared, vanished, or changed value.
    private static func changedPaths(
        before: [String: String], after: [String: String]
    ) -> Set<String> {
        var changed = Set<String>()
        for (path, value) in before where after[path] != value {
            changed.insert(path)
        }
        for path in after.keys where before[path] == nil {
            changed.insert(path)
        }
        return changed
    }
}
