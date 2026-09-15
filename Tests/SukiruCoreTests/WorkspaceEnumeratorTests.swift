import Foundation
import Testing

@testable import SukiruCore

/// Workspace root enumeration (architecture §4.1): user scope (canonical
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

    @Test("User scope: detected, leftover-but-present, and absent hosts (VAL-SCAN-012)")
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

    @Test(".DS_Store and .localized never flip a leftover into installed (VAL-SCAN-013)")
    func dsStoreLeftover() throws {
        let tree = try TempTree()
        try tree.dir(".qoder/skills")
        try tree.file(".qoder/.DS_Store", contents: "junk")
        try tree.file(".qoder/.localized")

        let qoder = enumerate(home: tree.path).first { $0.id == "host:qoder" }
        #expect(qoder != nil)
        #expect(qoder?.installed == false)
    }

    @Test("Empty-marker hosts are absent despite unrelated $HOME content (VAL-SCAN-014)")
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
