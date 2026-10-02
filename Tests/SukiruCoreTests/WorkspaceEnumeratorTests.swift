import Foundation
import Testing

@testable import SukiruCore

/// Workspace root enumeration: user scope (canonical
/// `~/.agents/skills` + detected/leftover host global dirs) and project scope
/// (canonical `.agents/skills` + per-host project dirs), with leftover roots
/// flagged `installed = false` but still present. Fixture-driven: each test
/// builds a real temp directory tree and enumerates through the real
/// filesystem probe.
@Suite("Workspace enumeration")
struct WorkspaceEnumeratorTests {
    private func enumerate(home: String, projectRoots: [String] = []) -> [Workspace] {
        let environment = SukiruEnvironment(
            reader: DictionaryEnvironmentReader(["SUKIRU_HOME": home])
        )
        let enumerator = WorkspaceEnumerator(
            environment: environment,
            fileSystem: DefaultFileSystemProbe()
        )
        return enumerator.enumerate(projectRoots: projectRoots)
    }

    private func ids(_ workspaces: [Workspace]) -> String {
        workspaces.map(\.id).joined(separator: " ")
    }

    @Test("User scope: detected, leftover-but-present, and absent hosts")
    func userScopeTriState() throws {
        let tree = try TempTree()
        let home = tree.path
        try tree.dir(".agents/skills")
        try tree.file(".qoder/skills/sprayed/SKILL.md", contents: "---\nname: sprayed\n---\n")
        try tree.file(".claude/config.json", contents: "{}")
        try tree.file(".claude/skills/tool/SKILL.md", contents: "---\nname: tool\n---\n")
        // No ~/.cursor anywhere: cursor is absent and must be omitted.

        let workspaces = enumerate(home: home)
        #expect(ids(workspaces) == "user host:claude-code host:qoder")
        #expect(workspaces.map(\.installed) == [true, true, false])
        #expect(workspaces.allSatisfy { $0.kind == .user })
        let roots = workspaces.map(\.root).joined(separator: " ")
        #expect(roots == "\(home)/.agents/skills \(home)/.claude/skills \(home)/.qoder/skills")
    }

    @Test(".DS_Store and .localized never flip a leftover into installed")
    func dsStoreLeftover() throws {
        let tree = try TempTree()
        try tree.dir(".qoder/skills")
        try tree.file(".qoder/.DS_Store", contents: "junk")
        try tree.file(".qoder/.localized")

        let qoder = enumerate(home: tree.path).first { $0.id == "host:qoder" }
        #expect(qoder != nil)
        #expect(qoder?.installed == false)
    }

    @Test("Empty-marker hosts are absent despite unrelated $HOME content")
    func emptyMarkerAbsent() throws {
        let tree = try TempTree()
        try tree.file("notes.txt", contents: "unrelated")
        try tree.dir("Projects/demo")

        // Only the canonical user store: claude-code / codex / mistral-vibe
        // must not be detected from mere $HOME content.
        #expect(ids(enumerate(home: tree.path)) == "user")
    }

    @Test("Hosts sharing the canonical store do not duplicate the user workspace")
    func canonicalNotDoubled() throws {
        let tree = try TempTree()
        try tree.dir(".agents/skills")
        // cline's global dir IS ~/.agents/skills (the canonical store).
        try tree.file(".cline/config.json", contents: "{}")

        #expect(ids(enumerate(home: tree.path)) == "user")
    }

    @Test("User-scope hosts sharing one global dir emit ONE workspace (amp/replit/universal)")
    func userScopeSharedDirDeduped() throws {
        let tree = try TempTree()
        // `~/.config/agents/skills` exists as CLI spray residue — amp,
        // replit AND universal all resolve their global skills dir to this
        // path via the Xdg default. Without dedup the enumerator emits three
        // workspaces with identical roots.
        try tree.dir(".config/agents/skills")

        let environment = SukiruEnvironment(
            reader: DictionaryEnvironmentReader(["SUKIRU_HOME": tree.path])
        )
        let detailed = WorkspaceEnumerator(
            environment: environment,
            fileSystem: DefaultFileSystemProbe()
        ).enumerateDetailed(projectRoots: [])

        let shared = detailed.filter { $0.workspace.root == "\(tree.path)/.config/agents/skills" }
        #expect(shared.count == 1)
        // The first non-absent host in table order (amp, index 2) lends its
        // id; all sharing hosts stay visible via candidateHosts.
        #expect(shared.first?.workspace.id == "host:amp")
        #expect(shared.first?.candidateHosts == ["amp", "replit", "universal"])
        // None of the three is *detected* (replit is cwd-only, universal is a
        // pseudo-host, amp's marker is absent) — the root is leftover residue.
        #expect(shared.first?.workspace.installed == false)
        // No other workspace carries the same root; ids stay unique overall.
        let allIDs = detailed.map(\.workspace.id)
        #expect(Set(allIDs).count == allIDs.count)
    }

    @Test("A shared user root lists every sharer and is installed when one is detected")
    func sharedRootInstalledWhenSharerDetected() throws {
        let tree = try TempTree()
        // zencoder and zenflow share `~/.zencoder/skills` and its marker. The
        // first sharer lends the id; both stay visible as candidates.
        try tree.dir(".zencoder/skills")
        try tree.file(".zencoder/config.json", contents: "{}")

        let environment = SukiruEnvironment(
            reader: DictionaryEnvironmentReader(["SUKIRU_HOME": tree.path])
        )
        let detailed = WorkspaceEnumerator(
            environment: environment,
            fileSystem: DefaultFileSystemProbe()
        ).enumerateDetailed(projectRoots: [])
        let shared = try #require(detailed.first { $0.workspace.id == "host:zencoder" })
        #expect(shared.workspace.root == "\(tree.path)/.zencoder/skills")
        #expect(shared.candidateHosts == ["zencoder", "zenflow"])
        #expect(shared.workspace.installed)
        #expect(!detailed.contains { $0.workspace.id == "host:zenflow" })
    }

    @Test("Kimi Code CLI's legacy global dir is still scanned through the Xdg sharers")
    func legacyKimiGlobalDirStillScanned() throws {
        let tree = try TempTree()
        // kimi-cli (skills@1.5.9) wrote to `~/.config/agents/skills`;
        // kimi-code-cli now uses the canonical store. Skills left at the old
        // path must stay in the scan set.
        try tree.dir(".config/agents/skills/old-skill")
        let workspaces = enumerate(home: tree.path)
        #expect(workspaces.contains { $0.root == "\(tree.path)/.config/agents/skills" })
    }

    @Test("Legacy global dirs are scanned only when present, flagged by detection")
    func legacyGlobalDirs() throws {
        let tree = try TempTree()
        #expect(!enumerate(home: tree.path).contains { $0.id.contains("#legacy:") })

        // A bare `skills` entry is spray residue, so Kilo Code is not detected.
        try tree.dir(".kilocode/skills/old")
        let leftover = try #require(
            enumerate(home: tree.path).first { $0.id == "host:kilo#legacy:.kilocode/skills" })
        #expect(leftover.root == "\(tree.path)/.kilocode/skills")
        #expect(leftover.kind == .user)
        #expect(!leftover.installed)
        #expect(WorkspaceEnumerator.isLegacy(workspaceID: leftover.id))

        try tree.file(".kilocode/settings.json", contents: "{}")
        let detected = try #require(
            enumerate(home: tree.path).first { $0.root == "\(tree.path)/.kilocode/skills" })
        #expect(detected.installed)
    }

    @Test("Legacy project dirs (Droid's .factory/skills, Kilo's .kilocode/skills) are scanned")
    func legacyProjectDirs() throws {
        let home = try TempTree()
        let project = try TempTree()
        let proj = project.path
        try project.dir(".factory/skills")
        try project.dir(".kilocode/skills")

        let workspaces = enumerate(home: home.path, projectRoots: [proj])
        #expect(
            ids(workspaces)
                == "user project:\(proj) project:\(proj)#droid#legacy:.factory/skills"
                + " project:\(proj)#kilo#legacy:.kilocode/skills")
        #expect(workspaces[2].root == "\(proj)/.factory/skills")
        #expect(workspaces[3].root == "\(proj)/.kilocode/skills")
        #expect(workspaces.allSatisfy { $0.installed })
    }

    @Test("Project scope: canonical store plus per-host project dirs")
    func projectScope() throws {
        let home = try TempTree()
        let project = try TempTree()
        let proj = project.path
        try project.dir(".agents/skills")
        try project.dir(".claude/skills")
        try project.dir(".qoder/skills")

        let workspaces = enumerate(home: home.path, projectRoots: [proj])
        let expectedIDs = "user project:\(proj) project:\(proj)#claude-code project:\(proj)#qoder"
        #expect(ids(workspaces) == expectedIDs)
        #expect(workspaces.allSatisfy { $0.installed })
        let projectWorkspaces = workspaces.filter { $0.kind == .project }
        #expect(projectWorkspaces.count == 3)
        #expect(projectWorkspaces[0].root == "\(proj)/.agents/skills")
        #expect(projectWorkspaces[1].root == "\(proj)/.claude/skills")
        #expect(projectWorkspaces[2].root == "\(proj)/.qoder/skills")
    }

    @Test("Project host dir is detected by its marker even without a skills dir")
    func projectMarkerOnly() throws {
        let home = try TempTree()
        let project = try TempTree()
        try project.dir(".roo")  // marker present, but no .roo/skills yet

        let workspaces = enumerate(home: home.path, projectRoots: [project.path])
        #expect(ids(workspaces) == "user project:\(project.path) project:\(project.path)#roo")
        #expect(workspaces.last?.root == "\(project.path)/.roo/skills")
    }

    @Test("Hosts sharing a project dir (trae/trae-cn) produce one workspace")
    func sharedProjectDirDeduped() throws {
        let home = try TempTree()
        let project = try TempTree()
        try project.dir(".trae/skills")

        let workspaces = enumerate(home: home.path, projectRoots: [project.path])
        let traeRoots = workspaces.filter { $0.root == "\(project.path)/.trae/skills" }
        #expect(traeRoots.count == 1)
    }

    @Test("Project root order does not affect the enumeration")
    func projectRootOrderIndependent() throws {
        let home = try TempTree()
        let first = try TempTree()
        let second = try TempTree()
        try first.dir(".claude/skills")
        try second.dir(".claude/skills")

        let forward = enumerate(home: home.path, projectRoots: [first.path, second.path])
        let reversed = enumerate(home: home.path, projectRoots: [second.path, first.path])
        #expect(forward == reversed)
        // Roots are emitted in sorted order regardless of input order.
        let sortedRoots = [first.path, second.path].sorted()
        let expectedIDs =
            "user project:\(sortedRoots[0]) project:\(sortedRoots[0])#claude-code"
            + " project:\(sortedRoots[1]) project:\(sortedRoots[1])#claude-code"
        #expect(ids(forward) == expectedIDs)
    }

    @Test("Leftover host roots stay in the scan set with installed=false")
    func leftoverRootsStayScannable() throws {
        let tree = try TempTree()
        try tree.file(".mux/skills/left/SKILL.md", contents: "---\nname: left\n---\n")

        let mux = enumerate(home: tree.path).first { $0.id == "host:mux" }
        #expect(mux != nil, "leftover root must stay in the scan set")
        #expect(mux?.installed == false)
        #expect(mux?.root == "\(tree.path)/.mux/skills")
    }
}
