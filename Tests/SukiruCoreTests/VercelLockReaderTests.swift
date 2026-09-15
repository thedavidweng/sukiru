import Foundation
import Testing

@testable import SukiruCore

/// Vercel lock readers (architecture §4.1, port-reference §6).
///
/// Project lock v1 is probed in the fixed order `skills-lock.json` →
/// `.agents/.skill-lock.json` → `.skill-lock.json` (first existing wins, never
/// merged). The global lock v3 lives at `$XDG_STATE_HOME/skills/.skill-lock.json`
/// when that variable is set AND non-empty (empty string is the archive's
/// relative-path bug — a regression test guards the fix), else
/// `<home>/.agents/.skill-lock.json`. Missing file = empty lock; older
/// version = incompatible issue; newer version = issue + best-effort parse.
@Suite("Vercel lock reader")
struct VercelLockReaderTests {
    private func reader(
        _ vars: [String: String],
        fileSystem: FileSystemProbe = DefaultFileSystemProbe()
    ) -> VercelLockReader {
        VercelLockReader(
            environment: SukiruEnvironment(reader: DictionaryEnvironmentReader(vars)),
            fileSystem: fileSystem
        )
    }

    private func lockJSON(version: Int, entryName: String) -> String {
        "{\"version\": \(version), \"skills\": {\"\(entryName)\": {\"source\": \"s\"}}}"
    }

    // MARK: Project probe order

    @Test("skills-lock.json wins over both shadowed probe files")
    func probeOrderFirstWins() throws {
        let tree = try TempTree()
        try tree.file("proj/skills-lock.json", contents: lockJSON(version: 1, entryName: "first"))
        try tree.file(
            "proj/.agents/.skill-lock.json", contents: lockJSON(version: 1, entryName: "mid"))
        try tree.file("proj/.skill-lock.json", contents: lockJSON(version: 1, entryName: "last"))
        let root = HostPathResolver.join(tree.path, "proj")
        let result = reader(["SUKIRU_HOME": tree.path]).readProjectLock(projectRoot: root)
        #expect(result.path == HostPathResolver.join(root, "skills-lock.json"))
        let lock = try #require(result.lock)
        #expect(lock.entries.keys.sorted() == ["first"])
        #expect(result.issue == nil)
    }

    @Test(".agents/.skill-lock.json wins over .skill-lock.json")
    func probeOrderMiddleBeatsLast() throws {
        let tree = try TempTree()
        try tree.file(
            "proj/.agents/.skill-lock.json", contents: lockJSON(version: 1, entryName: "mid"))
        try tree.file("proj/.skill-lock.json", contents: lockJSON(version: 1, entryName: "last"))
        let root = HostPathResolver.join(tree.path, "proj")
        let result = reader(["SUKIRU_HOME": tree.path]).readProjectLock(projectRoot: root)
        #expect(result.path == HostPathResolver.join(root, ".agents/.skill-lock.json"))
        #expect(result.lock?.entries.keys.sorted() == ["mid"])
    }

    @Test(".skill-lock.json is the last resort")
    func probeOrderLastResort() throws {
        let tree = try TempTree()
        try tree.file("proj/.skill-lock.json", contents: lockJSON(version: 1, entryName: "last"))
        let root = HostPathResolver.join(tree.path, "proj")
        let result = reader(["SUKIRU_HOME": tree.path]).readProjectLock(projectRoot: root)
        #expect(result.path == HostPathResolver.join(root, ".skill-lock.json"))
        #expect(result.lock?.entries.keys.sorted() == ["last"])
    }

    @Test("A missing project lock is an empty lock with no path and no issue")
    func projectLockMissing() throws {
        let tree = try TempTree()
        let root = try tree.dir("proj")
        let result = reader(["SUKIRU_HOME": tree.path]).readProjectLock(projectRoot: root)
        #expect(result.path == nil)
        let lock = try #require(result.lock)
        #expect(lock.version == VercelLockReader.projectLockVersion)
        #expect(lock.entries.isEmpty)
        #expect(result.issue == nil)
    }

    // MARK: Global lock path resolution

    @Test("A missing global lock is an empty v3 lock at the home path")
    func globalLockMissing() throws {
        let tree = try TempTree()
        let result = reader(["SUKIRU_HOME": tree.path]).readGlobalLock()
        #expect(result.path == HostPathResolver.join(tree.path, ".agents/.skill-lock.json"))
        let lock = try #require(result.lock)
        #expect(lock.version == VercelLockReader.globalLockVersion)
        #expect(lock.entries.isEmpty)
        #expect(result.issue == nil)
    }

    @Test("SUKIRU_XDG_STATE_HOME redirects the global lock read")
    func globalXDGOverrideWins() throws {
        let tree = try TempTree()
        let xdg = try tree.dir("xdg")
        try tree.file(
            "xdg/skills/.skill-lock.json", contents: lockJSON(version: 3, entryName: "xdg"))
        try tree.file(".agents/.skill-lock.json", contents: lockJSON(version: 3, entryName: "home"))
        let vars = ["SUKIRU_HOME": tree.path, "SUKIRU_XDG_STATE_HOME": xdg]
        let result = reader(vars).readGlobalLock()
        #expect(result.path == HostPathResolver.join(xdg, "skills/.skill-lock.json"))
        #expect(result.lock?.entries.keys.sorted() == ["xdg"])
    }

    @Test("An empty SUKIRU_XDG_STATE_HOME falls back to ~/.agents (regression guard)")
    func globalXDGEmptyStringFallsBack() throws {
        let tree = try TempTree()
        try tree.file("skills/.skill-lock.json", contents: lockJSON(version: 3, entryName: "trap"))
        try tree.file(".agents/.skill-lock.json", contents: lockJSON(version: 3, entryName: "home"))
        let vars = ["SUKIRU_HOME": tree.path, "SUKIRU_XDG_STATE_HOME": ""]
        let result = reader(vars).readGlobalLock()
        #expect(result.path == HostPathResolver.join(tree.path, ".agents/.skill-lock.json"))
        #expect(result.lock?.entries.keys.sorted() == ["home"])
    }

    @Test("The real XDG_STATE_HOME is honored on the real-machine path")
    func globalRealXDGStateHome() throws {
        let tree = try TempTree()
        let xdg = try tree.dir("xdg")
        try tree.file(
            "xdg/skills/.skill-lock.json", contents: lockJSON(version: 3, entryName: "xdg"))
        try tree.file(
            "home/.agents/.skill-lock.json", contents: lockJSON(version: 3, entryName: "home"))
        let home = HostPathResolver.join(tree.path, "home")
        let vars = ["HOME": home, "XDG_STATE_HOME": xdg]
        let result = reader(vars).readGlobalLock()
        #expect(result.path == HostPathResolver.join(xdg, "skills/.skill-lock.json"))
        #expect(result.lock?.entries.keys.sorted() == ["xdg"])
    }

    @Test("External XDG_STATE_HOME is suppressed under a SUKIRU_HOME override")
    func globalExternalEnvSuppressed() throws {
        let tree = try TempTree()
        let xdg = try tree.dir("xdg")
        try tree.file(
            "xdg/skills/.skill-lock.json", contents: lockJSON(version: 3, entryName: "xdg"))
        try tree.file(".agents/.skill-lock.json", contents: lockJSON(version: 3, entryName: "home"))
        let vars = ["SUKIRU_HOME": tree.path, "XDG_STATE_HOME": xdg]
        let result = reader(vars).readGlobalLock()
        #expect(result.path == HostPathResolver.join(tree.path, ".agents/.skill-lock.json"))
        #expect(result.lock?.entries.keys.sorted() == ["home"])
    }

    // MARK: Version handling

    @Test("An older-than-supported lock is incompatible; entries are not used")
    func oldVersionIncompatible() throws {
        let tree = try TempTree()
        try tree.file("proj/skills-lock.json", contents: lockJSON(version: 0, entryName: "old"))
        let root = HostPathResolver.join(tree.path, "proj")
        let result = reader(["SUKIRU_HOME": tree.path]).readProjectLock(projectRoot: root)
        let issue = try #require(result.issue)
        #expect(issue.kind == IssueKind.lockVersionUnsupported)
        #expect(issue.path == result.path)
        #expect(issue.message.contains("0"))
        #expect(issue.message.contains("1"))
        #expect(result.lock == nil)
    }

    @Test("A newer-than-supported lock raises an issue AND parses best-effort")
    func newerVersionBestEffort() throws {
        let tree = try TempTree()
        try tree.file(".agents/.skill-lock.json", contents: lockJSON(version: 4, entryName: "new"))
        let result = reader(["SUKIRU_HOME": tree.path]).readGlobalLock()
        let issue = try #require(result.issue)
        #expect(issue.kind == IssueKind.lockVersionUnsupported)
        #expect(issue.message.contains("4"))
        #expect(issue.message.contains("3"))
        let lock = try #require(result.lock)
        #expect(lock.version == 4)
        #expect(lock.entries.keys.sorted() == ["new"])
        #expect(lock.versionStatus == .newerThanSupported(found: 4, supported: 3))
    }

    // MARK: Malformed input

    @Test("Truncated JSON is a ledger-unreadable issue, never fatal")
    func malformedJSON() throws {
        let tree = try TempTree()
        try tree.file(
            ".agents/.skill-lock.json", contents: "{ \"version\": 3, \"skills\": { \"x\":")
        let result = reader(["SUKIRU_HOME": tree.path]).readGlobalLock()
        let issue = try #require(result.issue)
        #expect(issue.kind == IssueKind.ledgerUnreadable)
        #expect(issue.path == result.path)
        #expect(result.lock == nil)
    }

    @Test("A non-object top level is unreadable")
    func nonObjectTopLevel() throws {
        let tree = try TempTree()
        try tree.file(".agents/.skill-lock.json", contents: "[1, 2, 3]")
        let result = reader(["SUKIRU_HOME": tree.path]).readGlobalLock()
        #expect(result.issue?.kind == IssueKind.ledgerUnreadable)
        #expect(result.lock == nil)
    }

    @Test("A non-numeric version is unreadable")
    func nonNumericVersion() throws {
        let tree = try TempTree()
        try tree.file(".agents/.skill-lock.json", contents: "{\"version\": \"3\", \"skills\": {}}")
        let result = reader(["SUKIRU_HOME": tree.path]).readGlobalLock()
        #expect(result.issue?.kind == IssueKind.ledgerUnreadable)
        #expect(result.lock == nil)
    }

    // MARK: Field extraction and unknown-field preservation

    @Test("All known entry fields are extracted per architecture §4.1")
    func entryFieldsExtracted() throws {
        let tree = try TempTree()
        let json = """
            {"version": 1, "skills": {"demo": {
              "source": "owner/repo", "sourceType": "github",
              "sourceUrl": "https://github.com/owner/repo.git", "ref": "refs/heads/main",
              "skillPath": "skills/demo", "computedHash": "abc123",
              "installedAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-02T00:00:00Z",
              "pluginName": "plug", "sourceBaseUrl": "https://x", "wellKnownDigest": "sha"
            }}}
            """
        try tree.file("proj/skills-lock.json", contents: json)
        let root = HostPathResolver.join(tree.path, "proj")
        let result = reader(["SUKIRU_HOME": tree.path]).readProjectLock(projectRoot: root)
        let entry = try #require(result.lock?.entries["demo"])
        #expect(entry.source == "owner/repo")
        #expect(entry.sourceType == "github")
        #expect(entry.sourceUrl == "https://github.com/owner/repo.git")
        #expect(entry.ref == "refs/heads/main")
        #expect(entry.skillPath == "skills/demo")
        #expect(entry.computedHash == "abc123")
        #expect(entry.installedAt == "2026-01-01T00:00:00Z")
        #expect(entry.updatedAt == "2026-01-02T00:00:00Z")
        #expect(entry.extras.isEmpty)
        #expect(entry.isManaged)
    }

    @Test("Unknown entry- and file-level keys are preserved in extras, not dropped")
    func unknownFieldsPreserved() throws {
        let tree = try TempTree()
        let json = """
            {"version": 3, "dismissed": {"findSkillsPrompt": true},
             "lastSelectedAgents": ["claude-code"], "futureTopLevelKey": "preserved",
             "skills": {"demo": {"source": "s", "sourceType": "github",
               "skillFolderHash": "fff", "channel": "beta", "priority": 2}}}
            """
        try tree.file(".agents/.skill-lock.json", contents: json)
        let result = reader(["SUKIRU_HOME": tree.path]).readGlobalLock()
        let lock = try #require(result.lock)
        #expect(lock.extras["futureTopLevelKey"] == .string("preserved"))
        #expect(lock.dismissed != nil)
        #expect(lock.lastSelectedAgents == ["claude-code"])
        let entry = try #require(lock.entries["demo"])
        #expect(entry.skillFolderHash == "fff")
        #expect(entry.extras["channel"] == .string("beta"))
        #expect(entry.extras["priority"] == .int(2))
    }

    @Test("A lock path that exists but is unreadable content-wise never crashes")
    func directoryAtLockPath() throws {
        let tree = try TempTree()
        try tree.dir("proj/skills-lock.json")
        let root = HostPathResolver.join(tree.path, "proj")
        let result = reader(["SUKIRU_HOME": tree.path]).readProjectLock(projectRoot: root)
        #expect(result.issue?.kind == IssueKind.ledgerUnreadable)
        #expect(result.lock == nil)
    }
}
