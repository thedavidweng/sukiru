import Foundation
import Testing

@testable import SukiruCore

/// InventoryScanner tests (architecture §4.1, port-reference §3): placement
/// discovery, symlink/broken-symlink handling, the HostTable-derived ignore
/// list, alias collapse, and issue streaming — unit-level over TempTree.
@Suite("InventoryScanner placement discovery")
struct InventoryScannerTests {
    private func skillMD(_ name: String, internal isInternal: Bool = false) -> String {
        let metadata = isInternal ? "metadata:\n  internal: true\n" : ""
        return """
            ---
            name: \(name)
            description: The \(name) skill.
            \(metadata)---
            Body.
            """
    }

    private func scan(
        home: TempTree, projectRoots: [TempTree] = []
    ) throws -> ScanReport {
        var vars = ["SUKIRU_HOME": home.path]
        if !projectRoots.isEmpty {
            vars["SUKIRU_ROOTS"] = projectRoots.map(\.path).joined(separator: ":")
        }
        let environment = SukiruEnvironment(reader: DictionaryEnvironmentReader(vars))
        return try ScanEngine(environment: environment).scan(ScanRequest())
    }

    private func allPlacements(_ report: ScanReport) -> [Placement] {
        report.skills.flatMap(\.placements)
    }

    @Test("A skill directory becomes a directory placement with hash and canonical path")
    func directoryPlacement() throws {
        let home = try TempTree()
        try home.file(".agents/skills/alpha/SKILL.md", contents: skillMD("alpha"))

        let report = try scan(home: home)
        let alpha = try #require(report.skills.first { $0.name == "alpha" })
        #expect(report.skills.count == 1)
        #expect(alpha.scope == .user)
        #expect(alpha.ambiguous == false)
        let placement = try #require(alpha.placements.first)
        #expect(alpha.placements.count == 1)
        #expect(placement.kind == .directory)
        #expect(placement.linkTarget == nil)
        #expect(placement.canonicalPath?.hasSuffix("/.agents/skills/alpha") == true)
        #expect(placement.contentHash?.count == 64)
        #expect(placement.internal == false)
        #expect(report.issues.isEmpty)
    }

    @Test("A symlink to a skill dir becomes a symlink placement resolving to the canonical path")
    func symlinkPlacement() throws {
        let home = try TempTree()
        try home.file(".claude/config.json", contents: "{}")
        let canonical = try home.file(".agents/skills/demo/SKILL.md", contents: skillMD("demo"))
        let target = URL(fileURLWithPath: canonical).deletingLastPathComponent().path
        let link = try home.symlink(".claude/skills/demo", to: target)

        let report = try scan(home: home)
        let demo = try #require(report.skills.first { $0.name == "demo" })
        #expect(report.skills.count == 1, "alias placements collapse to ONE logical skill")
        #expect(demo.placements.count == 2)
        #expect(demo.ambiguous == false)

        let directory = try #require(demo.placements.first { $0.kind == .directory })
        let symlink = try #require(demo.placements.first { $0.kind == .symlink })
        #expect(symlink.path == link)
        #expect(symlink.linkTarget == target)
        #expect(symlink.canonicalPath == directory.canonicalPath)
        #expect(symlink.canonicalPath != nil)
        #expect(symlink.contentHash == directory.contentHash)
    }

    @Test("A dangling symlink is a first-class brokenSymlink placement with issue and finding")
    func brokenSymlink() throws {
        let home = try TempTree()
        try home.file(".claude/config.json", contents: "{}")
        let link = try home.symlink(".claude/skills/rotted", to: "/nonexistent/rotted-target")

        let report = try scan(home: home)
        let rotted = try #require(report.skills.first { $0.name == "rotted" })
        let placement = try #require(rotted.placements.first)
        #expect(placement.kind == .brokenSymlink)
        #expect(placement.path == link)
        #expect(placement.linkTarget == "/nonexistent/rotted-target")
        #expect(placement.canonicalPath == nil)
        #expect(placement.contentHash == nil)

        #expect(report.issues.contains { $0.kind == "broken-symlink" && $0.path == link })
        let finding = try #require(report.findings.first { $0.ruleID == "broken-symlink" })
        #expect(finding.severity == .action)
        #expect(finding.skillName == "rotted")
        #expect(finding.evidence.contains { $0.kind == "linkPath" && $0.detail == link })
        let targetEvidence = finding.evidence.contains {
            $0.kind == "linkTarget" && $0.detail == "/nonexistent/rotted-target"
        }
        #expect(targetEvidence)
    }

    @Test("Symlinks to non-skill dirs, files, and ancestor cycles are silently skipped")
    func nonSkillSymlinksSkipped() throws {
        let home = try TempTree()
        try home.file(".agents/skills/real/SKILL.md", contents: skillMD("real"))
        try home.dir(".agents/skills/plain-dir")
        try home.symlink(".agents/skills/dir-link", to: home.path + "/.agents/skills/plain-dir")
        try home.file(".agents/skills/some.txt", contents: "x")
        try home.symlink(".agents/skills/file-link", to: home.path + "/.agents/skills/some.txt")
        // A link to an ancestor directory would cycle if descended into.
        try home.symlink(".agents/skills/loop", to: home.path)

        let report = try scan(home: home)
        #expect(report.skills.map(\.name) == ["real"])
        #expect(report.issues.isEmpty)
    }

    @Test("Noise containers never become placements, even with a valid SKILL.md inside")
    func ignoreList() throws {
        let home = try TempTree()
        try home.file(".agents/skills/real-skill/SKILL.md", contents: skillMD("real-skill"))
        let noiseDirs =
            "node_modules __pycache__ __pypackages__ dist build .git .archive .hidden-junk"
            .split(separator: " ")
        for noise in noiseDirs {
            try home.file(".agents/skills/\(noise)/SKILL.md", contents: skillMD(String(noise)))
        }

        let report = try scan(home: home)
        #expect(report.skills.map(\.name) == ["real-skill"])
        #expect(allPlacements(report).count == 1)
    }

    @Test("Known HostTable-derived dot-containers and curated buckets are descended into")
    func knownContainersDescended() throws {
        let home = try TempTree()
        try home.file(
            ".agents/skills/.claude/inner/SKILL.md", contents: skillMD("nested-in-claude"))
        try home.file(
            ".agents/skills/.curated/curated-skill/SKILL.md", contents: skillMD("curated-skill"))

        let report = try scan(home: home)
        #expect(report.skills.map(\.name) == ["curated-skill", "nested-in-claude"])
    }

    @Test("An unreadable directory becomes an issue and never suppresses healthy skills")
    func unreadableDirectory() throws {
        let home = try TempTree()
        try home.file(".agents/skills/healthy/SKILL.md", contents: skillMD("healthy"))
        let locked = try home.dir(".agents/skills/locked-dir")
        try home.file(".agents/skills/locked-dir/inner/SKILL.md", contents: skillMD("inner"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: locked)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked)
        }

        let report = try scan(home: home)
        #expect(report.skills.map(\.name) == ["healthy"])
        #expect(
            report.issues.contains { $0.kind == "directory-unreadable" && $0.path == locked })
    }

    @Test("Malformed SKILL.md flows into the issue stream without suppressing other skills")
    func malformedSkillMD() throws {
        let home = try TempTree()
        try home.file(
            ".agents/skills/nameless/SKILL.md",
            contents: "---\ndescription: no name here\n---\nBody.\n")
        try home.file(".agents/skills/good/SKILL.md", contents: skillMD("good"))

        let report = try scan(home: home)
        #expect(report.skills.map(\.name) == ["good"])
        #expect(report.issues.contains { $0.kind == "skill-md-invalid" })
        #expect(
            report.issues.contains { $0.path.hasSuffix(".agents/skills/nameless/SKILL.md") })
    }

    @Test("Stray files and skill-less directories never become placements")
    func strayEntriesIgnored() throws {
        let home = try TempTree()
        try home.file(".agents/skills/README.txt", contents: "hello")
        try home.file(".agents/skills/loose.bin", contents: "0")
        try home.file(".agents/skills/no-skill-md/helper.py", contents: "pass")
        try home.file(".agents/skills/real/SKILL.md", contents: skillMD("real"))

        let report = try scan(home: home)
        #expect(report.skills.map(\.name) == ["real"])
    }

    @Test("An absent workspace root is silent, never an issue")
    func absentWorkspaceRootSilent() throws {
        let home = try TempTree()
        let report = try scan(home: home)
        #expect(report.skills.isEmpty)
        #expect(report.issues.isEmpty)
        #expect(report.findings.isEmpty)
    }

    @Test("The same name in user scope and a project root stays two separate skills")
    func scopeSeparation() throws {
        let home = try TempTree()
        let project = try TempTree()
        try home.file(".agents/skills/shared/SKILL.md", contents: skillMD("shared"))
        try project.file(".agents/skills/shared/SKILL.md", contents: skillMD("shared"))

        let report = try scan(home: home, projectRoots: [project])
        let shared = report.skills.filter { $0.name == "shared" }
        #expect(shared.count == 2)
        #expect(shared.contains { $0.scope == .user })
        #expect(shared.contains { $0.scope == .project })
    }

    @Test("Two hash-divergent unexplained copies of one name in a scope are ONE ambiguous skill")
    func distinctCopiesAmbiguous() throws {
        let home = try TempTree()
        try home.file(".claude/config.json", contents: "{}")
        try home.file(".agents/skills/dup/SKILL.md", contents: skillMD("dup"))
        try home.file(".claude/skills/dup/SKILL.md", contents: skillMD("dup"))
        // D23: divergence comes from content hashes, not paths.
        try home.file(".claude/skills/dup/extra.txt", contents: "divergent")

        let report = try scan(home: home)
        let dup = try #require(report.skills.first { $0.name == "dup" })
        #expect(report.skills.count == 1)
        #expect(dup.placements.count == 2)
        #expect(dup.ambiguous == true, "D23: unexplained copies with ≥2 distinct hashes")
    }

    @Test("Placements carry the full candidate host set for shared dirs (trap 12)")
    func candidateHostSets() throws {
        let home = try TempTree()
        let project = try TempTree()
        try home.file(".agents/skills/foo/SKILL.md", contents: skillMD("foo"))
        try project.file(".trae/skills/bar/SKILL.md", contents: skillMD("bar"))

        let vars = ["SUKIRU_HOME": home.path, "SUKIRU_ROOTS": project.path]
        let environment = SukiruEnvironment(reader: DictionaryEnvironmentReader(vars))
        let probe = DefaultFileSystemProbe()
        let detailed = WorkspaceEnumerator(environment: environment, fileSystem: probe)
            .enumerateDetailed(projectRoots: [project.path])
        let result = InventoryScanner(fileSystem: probe).scan(workspaces: detailed)

        let canonical = try #require(result.placements.first { $0.name == "foo" })
        // cline/dexto/warp/zed all share the canonical `~/.agents/skills` dir.
        #expect(
            Set(canonical.candidateHosts).isSuperset(of: ["cline", "dexto", "warp", "zed"]))

        let trae = try #require(result.placements.first { $0.name == "bar" })
        // trae and trae-cn share the project dir `.trae/skills` — never one id.
        #expect(trae.candidateHosts == ["trae", "trae-cn"])
    }

    @Test("The derived container allowlist comes from HostTable, with no phantom entries")
    func derivedAllowlist() {
        let known = ContainerIgnoreList.knownContainerNames
        // Derived from HostTable projectSkillDir first components.
        #expect(known.contains(".claude"))
        #expect(known.contains(".agents"))
        #expect(known.contains(".trae"))
        #expect(known.contains(".tabnine"))
        // Curated sub-buckets survive.
        #expect(known.contains(".curated"))
        #expect(known.contains(".experimental"))
        #expect(known.contains(".system"))
        // Archive phantoms matching no host are gone (port-reference §3).
        #expect(!known.contains(".opencode"))
        #expect(!known.contains(".autohand"))
        // Every dotted first component of a host projectSkillDir is known.
        for host in HostTable.hosts {
            let first = String(host.projectSkillDir.split(separator: "/").first ?? "")
            if first.hasPrefix(".") {
                #expect(known.contains(first), "\(first) from \(host.id) must be known")
            }
        }
        // Unconditional ignores.
        let noiseDirs = "node_modules __pycache__ __pypackages__ dist build .git .archive"
            .split(separator: " ")
        for noise in noiseDirs {
            #expect(ContainerIgnoreList.isIgnored(name: String(noise)))
        }
        #expect(ContainerIgnoreList.isIgnored(name: ".unknown-hidden"))
        #expect(!ContainerIgnoreList.isIgnored(name: ".claude"))
        #expect(!ContainerIgnoreList.isIgnored(name: "plain-name"))
    }
}

/// Fixture-tree end-to-end checks over the checked-in scan-area corpus
/// (VAL-SCAN-006/008/009/010/011/035 fixtures).
@Suite("InventoryScanner against checked-in fixtures")
struct InventoryScannerFixtureTests {
    private func scan(fixture name: String, projectRoot: String? = nil) throws -> ScanReport {
        var vars = ["SUKIRU_HOME": FixturePaths.tree(name)]
        if let projectRoot {
            vars["SUKIRU_ROOTS"] = projectRoot
        }
        let environment = SukiruEnvironment(reader: DictionaryEnvironmentReader(vars))
        return try ScanEngine(environment: environment).scan(ScanRequest())
    }

    /// CM-style two-part fixtures: fake home under `.home`, project under `proj`.
    private func scanSplitFixture(_ name: String) throws -> ScanReport {
        let tree = FixturePaths.tree(name)
        let vars = ["SUKIRU_HOME": tree + "/.home", "SUKIRU_ROOTS": tree + "/proj"]
        let environment = SukiruEnvironment(reader: DictionaryEnvironmentReader(vars))
        return try ScanEngine(environment: environment).scan(ScanRequest())
    }

    private func allPlacements(_ report: ScanReport) -> [Placement] {
        report.skills.flatMap(\.placements)
    }

    @Test("alias-link-mode: demo collapses to ONE skill with 3 placements, equal canonical paths")
    func aliasLinkMode() throws {
        let report = try scan(fixture: "alias-link-mode")
        let demo = try #require(report.skills.first { $0.name == "demo" })
        #expect(report.skills.count == 1)
        #expect(demo.placements.count == 3)
        #expect(demo.ambiguous == false)
        let kinds = demo.placements.map(\.kind).sorted { $0.rawValue < $1.rawValue }
        #expect(kinds == [.directory, .symlink, .symlink])
        let canonicals = Set(demo.placements.compactMap(\.canonicalPath))
        #expect(canonicals.count == 1, "all placements resolve to one canonical path")
        for placement in demo.placements where placement.kind == .symlink {
            #expect(placement.linkTarget != nil)
        }
    }

    @Test("FIX-INTERNAL: internal skills are inventoried and flagged")
    func internalFlag() throws {
        let report = try scan(fixture: "FIX-INTERNAL")
        let hidden = try #require(report.skills.first { $0.name == "hidden-helper" })
        let normal = try #require(report.skills.first { $0.name == "normal" })
        #expect(hidden.placements.first?.internal == true)
        #expect(normal.placements.first?.internal == false)
    }

    @Test("FIX-BIG: all 40 skills inventory, sorted, and repeat scans are byte-identical")
    func bigFixtureDeterminism() throws {
        let first = try scan(fixture: "FIX-BIG")
        let second = try scan(fixture: "FIX-BIG")
        #expect(first.skills.count == 40)
        #expect(allPlacements(first).count == 40)
        #expect(first.skills.map(\.name) == first.skills.map(\.name).sorted())
        #expect(try first.jsonData() == second.jsonData(), "identical tree → identical report")
    }

    @Test("ignore-list fixture: exactly the one real skill inventories")
    func ignoreListFixture() throws {
        let report = try scan(fixture: "ignore-list")
        #expect(report.skills.map(\.name) == ["real-skill"])
        #expect(allPlacements(report).count == 1)
    }

    @Test("multi-host-inventory: exactly the five manifest placements with correct attribution")
    func multiHostInventory() throws {
        let report = try scanSplitFixture("multi-host-inventory")
        let placements = allPlacements(report)
        #expect(placements.count == 5)
        #expect(placements.allSatisfy { $0.kind == .directory })
        let names = report.skills.map(\.name).sorted()
        #expect(names == ["canon-tool", "claude-tool", "codex-tool", "proj-canon", "proj-claude"])
        // Workspace attribution: each placement path lives under its workspace root.
        let roots = report.workspaces.map(\.root)
        #expect(
            placements.allSatisfy { placement in
                roots.contains { placement.path.hasPrefix($0 + "/") }
            })
        #expect(report.skills.filter { $0.scope == .user }.count == 3)
        #expect(report.skills.filter { $0.scope == .project }.count == 2)
    }

    @Test("FIX-GARBAGE: broken symlink surfaces, defects never suppress the survivor")
    func garbageFixture() throws {
        let report = try scan(fixture: "FIX-GARBAGE")

        let rotted = try #require(report.skills.first { $0.name == "rotted" })
        let placement = try #require(rotted.placements.first)
        #expect(placement.kind == .brokenSymlink)
        #expect(placement.linkTarget == "/nonexistent/rotted-target")
        #expect(placement.canonicalPath == nil)
        #expect(placement.contentHash == nil)
        #expect(report.findings.contains { $0.ruleID == "broken-symlink" })

        // The healthy skill survives alongside every planted defect.
        #expect(report.skills.contains { $0.name == "survivor" })
        // Malformed frontmatter → issue, no placement.
        #expect(report.issues.contains { $0.kind == "skill-md-invalid" })
        #expect(!report.skills.contains { $0.name == "nameless" })
        // Stray files and skill-less dirs are not placements.
        let paths = allPlacements(report).map(\.path)
        #expect(!paths.contains { $0.contains("README.txt") || $0.contains("loose.bin") })
        #expect(!paths.contains { $0.contains("no-skill-md") })
    }
}
