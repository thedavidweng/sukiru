import Foundation
import Testing

@testable import SukiruCore

/// OwnershipResolver over the checked-in fixture corpus (VAL-SCAN-015…021,
/// 055, 056).
@Suite("OwnershipResolver against checked-in fixtures")
struct OwnershipResolverFixtureTests {
    @Test("own-vercel: both scopes resolve vercel, provenance byte-equal to the fixture locks")
    func ownVercel() throws {
        let tree = FixturePaths.tree("own-vercel")
        let vars = ["SUKIRU_HOME": tree + "/.home", "SUKIRU_ROOTS": tree + "/proj"]
        let environment = SukiruEnvironment(reader: DictionaryEnvironmentReader(vars))
        let report = try ScanEngine(environment: environment).scan(ScanRequest())

        let globalSkill = try #require(report.skills.first { $0.name == "global-tool" })
        #expect(globalSkill.ownership == .vercel)
        let projectSkill = try #require(report.skills.first { $0.name == "proj-tool" })
        #expect(projectSkill.ownership == .vercel)

        // Byte-equality against the fixture lock entries themselves.
        let reader = VercelLockReader(environment: environment)
        let globalEntry = try #require(reader.readGlobalLock().lock?.entries["global-tool"])
        let global = try #require(globalSkill.provenance.vercel)
        #expect(global.source == globalEntry.source)
        #expect(global.sourceType == globalEntry.sourceType)
        #expect(global.sourceUrl == globalEntry.sourceUrl)
        #expect(global.ref == globalEntry.ref)
        #expect(global.skillPath == globalEntry.skillPath)
        #expect(global.skillFolderHash == globalEntry.skillFolderHash)
        #expect(global.computedHash == nil)
        #expect(global.installedAt == globalEntry.installedAt)
        #expect(global.updatedAt == globalEntry.updatedAt)

        let projectEntry = try #require(
            reader.readProjectLock(projectRoot: tree + "/proj").lock?.entries["proj-tool"])
        let project = try #require(projectSkill.provenance.vercel)
        #expect(project.computedHash == projectEntry.computedHash)
        #expect(project.computedHash != nil)
        #expect(project.skillFolderHash == nil)
        #expect(project.source == projectEntry.source)
        #expect(project.ref == projectEntry.ref)

        #expect(!report.findings.contains { $0.ruleID == "double-booked" })
        #expect(!report.findings.contains { $0.ruleID == "files-without-lock" })
    }

    @Test("own-github: both skills resolve github with full provenance and pin tri-state")
    func ownGitHub() throws {
        let report = try OwnershipBuilders.scan(fixture: "own-github")

        let pinned = try #require(report.skills.first { $0.name == "pinned-tool" })
        #expect(pinned.ownership == .github)
        let pinnedGitHub = try #require(pinned.provenance.github)
        #expect(pinnedGitHub.repo == "https://github.com/thedavidweng/skills.git")
        #expect(pinnedGitHub.path == "tools/pinned-tool/SKILL.md")
        #expect(pinnedGitHub.ref == "refs/heads/main")
        #expect(pinnedGitHub.treeSha == String(repeating: "a", count: 40))
        #expect(pinnedGitHub.pinned == true)

        let unpinned = try #require(report.skills.first { $0.name == "unpinned-tool" })
        #expect(unpinned.ownership == .github)
        let unpinnedGitHub = try #require(unpinned.provenance.github)
        #expect(unpinnedGitHub.repo == "https://github.com/thedavidweng/skills")
        #expect(unpinnedGitHub.pinned == false, "absent github-pinned key means unpinned")

        #expect(!report.findings.contains { $0.ruleID == "files-without-lock" })
        #expect(!report.findings.contains { $0.ruleID == "double-booked" })
    }

    @Test("own-double: double-booked with both-ledger evidence")
    func ownDouble() throws {
        let report = try OwnershipBuilders.scan(fixture: "own-double")
        let skill = try #require(report.skills.first { $0.name == "double-tool" })
        #expect(skill.ownership == .doubleBooked)
        #expect(skill.ambiguous == false)
        #expect(skill.provenance.vercel != nil)
        #expect(skill.provenance.github != nil)

        let finding = try #require(report.findings.first { $0.ruleID == "double-booked" })
        #expect(finding.severity == .action)
        let tree = FixturePaths.tree("own-double")
        let lockPathEvidence = finding.evidence.contains {
            $0.kind == "lockPath" && $0.detail == tree + "/.agents/.skill-lock.json"
        }
        #expect(lockPathEvidence)
        #expect(finding.evidence.contains { $0.kind == "entryKey" && $0.detail == "double-tool" })
        let skillMdEvidence = finding.evidence.contains {
            $0.kind == "skillMdPath"
                && $0.detail == tree + "/.agents/skills/double-tool/SKILL.md"
        }
        #expect(skillMdEvidence)
        let repoEvidence = finding.evidence.contains {
            $0.kind == "githubRepo" && $0.detail == "https://github.com/thedavidweng/skills"
        }
        #expect(repoEvidence)
    }

    @Test("FIX-AMBIGUOUS: ownerless + ambiguous, both paths in evidence, lock claim as data")
    func fixAmbiguous() throws {
        let report = try OwnershipBuilders.scan(fixture: "FIX-AMBIGUOUS")
        let dup = try #require(report.skills.first { $0.name == "dup" })
        #expect(dup.ownership == .ownerless)
        #expect(dup.ambiguous == true)
        // The lock claim is surfaced as data (VAL-SCAN-018), not ownership.
        #expect(dup.provenance.vercel?.skillFolderHash == String(repeating: "6", count: 40))

        let finding = try #require(report.findings.first { $0.ruleID == "ambiguous-name" })
        #expect(finding.severity == .warning)
        let tree = FixturePaths.tree("FIX-AMBIGUOUS")
        let paths = Set(finding.evidence.filter { $0.kind == "placementPath" }.map(\.detail))
        #expect(
            paths == [tree + "/.claude/skills/dup", tree + "/.codex/skills/dup"],
            "one placementPath per colliding placement")
    }

    @Test("FIX-FILES-NO-LOCK: ownerless with a files-without-lock listing naming the path")
    func fixFilesNoLock() throws {
        let report = try OwnershipBuilders.scan(fixture: "FIX-FILES-NO-LOCK")
        let orphan = try #require(report.skills.first { $0.name == "orphan" })
        #expect(orphan.ownership == .ownerless)
        #expect(orphan.ambiguous == false)

        let finding = try #require(report.findings.first { $0.ruleID == "files-without-lock" })
        #expect(finding.severity == .info)
        let tree = FixturePaths.tree("FIX-FILES-NO-LOCK")
        let pathEvidence = finding.evidence.contains {
            $0.kind == "placementPath" && $0.detail == tree + "/.agents/skills/orphan"
        }
        #expect(pathEvidence)
    }

    @Test("alias-link-mode: no ambiguous-name finding, ambiguous=false, ownership resolved")
    func aliasLinkMode() throws {
        let report = try OwnershipBuilders.scan(fixture: "alias-link-mode")
        let demo = try #require(report.skills.first { $0.name == "demo" })
        #expect(demo.ambiguous == false)
        #expect(
            !report.findings.contains { $0.ruleID == "ambiguous-name" },
            "D1 negative: alias placements are never ambiguous")
        // No ledger claims in this tree: ownerless, and the ownerless listing
        // names all three placement paths.
        #expect(demo.ownership == .ownerless)
        let finding = try #require(
            report.findings.first { $0.ruleID == "files-without-lock" && $0.skillName == "demo" })
        #expect(finding.evidence.filter { $0.kind == "placementPath" }.count == 3)
    }

    @Test("prov-cross-ws: identical github provenance in every workspace context")
    func provCrossWorkspace() throws {
        let report = try OwnershipBuilders.scanSplitFixture("prov-cross-ws")
        let shared = report.skills.filter { $0.name == "shared" }
        #expect(shared.count == 2)
        let userSkill = try #require(shared.first { $0.scope == .user })
        let projectSkill = try #require(shared.first { $0.scope == .project })
        #expect(userSkill.ownership == .github)
        #expect(projectSkill.ownership == .github)

        let userGitHub = try #require(userSkill.provenance.github)
        let projectGitHub = try #require(projectSkill.provenance.github)
        #expect(userGitHub == projectGitHub, "provenance byte-equal across workspace contexts")
        #expect(userGitHub.ref == "refs/heads/main")
        #expect(userGitHub.pinned == true)
        #expect(userGitHub.treeSha == String(repeating: "e", count: 40))
    }

    @Test("own-per-project: shared is vercel in p1 and ownerless in p2 (VAL-SCAN-055)")
    func ownPerProject() throws {
        let report = try OwnershipBuilders.scanSplitFixture("own-per-project", roots: ["p1", "p2"])
        let tree = FixturePaths.tree("own-per-project")
        let shared = report.skills.filter { $0.name == "shared" }
        #expect(shared.count == 2)

        let locked = try #require(
            shared.first { $0.placements.first?.path.hasPrefix(tree + "/p1/") == true })
        #expect(locked.ownership == .vercel)
        #expect(locked.provenance.vercel?.computedHash != nil)

        let free = try #require(
            shared.first { $0.placements.first?.path.hasPrefix(tree + "/p2/") == true })
        #expect(free.ownership == .ownerless)
        #expect(free.provenance.vercel == nil)

        let finding = try #require(
            report.findings.first { $0.ruleID == "files-without-lock" && $0.skillName == "shared" })
        #expect(finding.workspaceID == "project:\(tree)/p2")
    }

    @Test("scope-isolation: shared-skill is vercel in both scopes, orphans listed per scope")
    func scopeIsolation() throws {
        let report = try OwnershipBuilders.scanSplitFixture("scope-isolation")
        let tree = FixturePaths.tree("scope-isolation")

        let shared = report.skills.filter { $0.name == "shared-skill" }
        #expect(shared.count == 2)
        #expect(shared.allSatisfy { $0.ownership == .vercel })
        #expect(shared.allSatisfy { !$0.ambiguous })
        let userShared = try #require(shared.first { $0.scope == .user })
        let projectShared = try #require(shared.first { $0.scope == .project })
        #expect(userShared.provenance.vercel?.skillFolderHash != nil)
        #expect(userShared.provenance.vercel?.computedHash == nil)
        #expect(projectShared.provenance.vercel?.computedHash != nil)
        #expect(projectShared.provenance.vercel?.skillFolderHash == nil)

        let userOrphan = try #require(report.skills.first { $0.name == "user-orphan" })
        #expect(userOrphan.ownership == .ownerless)
        let projectOrphan = try #require(report.skills.first { $0.name == "proj-orphan" })
        #expect(projectOrphan.ownership == .ownerless)

        let orphanFindings = report.findings.filter { $0.ruleID == "files-without-lock" }
        let userFinding = try #require(orphanFindings.first { $0.skillName == "user-orphan" })
        #expect(userFinding.workspaceID == "user")
        let projectFinding = try #require(orphanFindings.first { $0.skillName == "proj-orphan" })
        #expect(projectFinding.workspaceID == "project:\(tree)/proj")
    }

    @Test("FIX-DUPLICATES under D23: div-demo stays ambiguous, exact-demo does not")
    func fixDuplicatesRefinedAmbiguity() throws {
        let report = try OwnershipBuilders.scan(fixture: "FIX-DUPLICATES")

        // Two DIVERGENT copies, no ledger story for either: unexplained with
        // ≥2 distinct hashes ⇒ ambiguous (D23).
        let div = try #require(report.skills.first { $0.name == "div-demo" })
        #expect(div.ambiguous == true)
        #expect(div.ownership == .ownerless)
        #expect(
            report.findings.contains {
                $0.ruleID == "ambiguous-name" && $0.skillName == "div-demo"
            })

        // Two BYTE-IDENTICAL copies with no ledger claim: unexplained but a
        // single shared hash ⇒ NOT ambiguous (D23); plain ownerless with the
        // inventory listing.
        let exact = try #require(report.skills.first { $0.name == "exact-demo" })
        #expect(exact.ambiguous == false)
        #expect(exact.ownership == .ownerless)
        #expect(
            !report.findings.contains {
                $0.ruleID == "ambiguous-name" && $0.skillName == "exact-demo"
            })
        #expect(
            report.findings.contains {
                $0.ruleID == "files-without-lock" && $0.skillName == "exact-demo"
            })
    }

    @Test("clean-copy-mode: the stock copy-mode layout is vercel-owned and never ambiguous")
    func cleanCopyModeOwnership() throws {
        let report = try OwnershipBuilders.scanSplitFixture("clean-copy-mode")
        let webTool = try #require(report.skills.first { $0.name == "web-tool" })
        #expect(webTool.placements.count == 2)
        #expect(
            webTool.ambiguous == false,
            "D23(a): the host copy is hash-identical to the lock-anchored canonical placement")
        #expect(webTool.ownership == .vercel)
        #expect(!report.findings.contains { $0.ruleID == "ambiguous-name" })
        let duplicate = try #require(
            report.findings.first {
                $0.ruleID == "cross-host-duplicate" && $0.skillName == "web-tool"
            })
        #expect(duplicate.evidence.contains { $0.kind == "subtype" && $0.detail == "exact" })
    }

    @Test("FIX-CLEAN: vercel ownership and zero findings")
    func fixClean() throws {
        let report = try OwnershipBuilders.scan(fixture: "FIX-CLEAN")
        let greet = try #require(report.skills.first { $0.name == "greet" })
        #expect(report.skills.count == 1)
        #expect(greet.ownership == .vercel)
        #expect(greet.ambiguous == false)
        #expect(greet.provenance.vercel?.skillFolderHash != nil)
        #expect(greet.provenance.vercel?.computedHash == nil)
        #expect(report.findings.isEmpty)
    }
}
