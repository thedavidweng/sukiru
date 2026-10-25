import Foundation
import Testing

@testable import SukiruCore

@Suite(
    "Real pnpm 12.11.0 lifecycle in isolated HOMEs", .serialized,
    .enabled(if: PnpmRealSupport.enabled, "set SUKIRU_PNPM_E2E=1 to run pinned real-pnpm tests")
)
struct PnpmRealEndToEndTests {
    private let alpha = "@sukiru/real-alpha"
    private let firstSelector = "@sukiru/real-alpha@file:../alpha-v1.tgz"
    private let secondSelector = "@sukiru/real-alpha@file:../alpha-v2.tgz"

    @Test("Pending, approval, upgrade, resync, denial and removal stay passive in Scan and Health")
    func lifecycle() throws {
        let sandbox = try PnpmRealSandbox()
        try sandbox.package()
        try sandbox.package(version: "2.0.0", archive: "alpha-v2.tgz", addedSkill: true)
        try sandbox.project(dependencies: [alpha: "file:../alpha-v1.tgz"])
        #expect(sandbox.environment["HOME"] == sandbox.home)
        #expect(sandbox.environment["CLAUDECODE"] == nil)
        #expect(sandbox.environment["CODEBUDDY_CLI"] == nil)
        #expect(sandbox.environment["ANTHROPIC_API_KEY"] == nil)
        #expect(sandbox.environment["OPENAI_API_KEY"] == nil)
        try sandbox.install()
        #expect(try sandbox.modules()["pendingSkills"] as? [String] == [firstSelector])
        let pending = try sandbox.scan()
        #expect(pending.skills.isEmpty)
        try expectObservation(
            pending, selector: firstSelector, permission: .pending, installed: false)
        try approveInitialPackage(sandbox)
        try upgradeAndResyncPackage(sandbox)
        try denyAndRemovePackage(sandbox)
    }

    private func approveInitialPackage(_ sandbox: PnpmRealSandbox) throws {
        try sandbox.pnpm(["approve", firstSelector, "--yes"])
        let approved = try sandbox.scan()
        #expect(approved.skills.count == 1)
        let skill = try #require(approved.skills.first)
        #expect(skill.name == "shared-guide")
        #expect(skill.packageQualifiedName == "pnpm-@sukiru+real-alpha-guide")
        #expect(skill.ownership == .pnpm)
        #expect(skill.placements.count == 2)
        #expect(skill.provenance.pnpm?.allSatisfy { $0.packageVersion == "1.0.0" } == true)
        #expect(approved.issues.isEmpty)
        #expect(approved.findings.allSatisfy { ProblemKind.of($0) == .note })
        try expectObservation(
            approved, selector: firstSelector, permission: .approved, installed: true)
        try assertLinks(sandbox, count: 2)
        try sandbox.assertReadOnly(approved)
    }

    private func upgradeAndResyncPackage(_ sandbox: PnpmRealSandbox) throws {
        try sandbox.pnpm([
            "add", alpha + "@file:../alpha-v2.tgz", "--offline", "--ignore-scripts"
        ])
        let upgradedPending = try sandbox.scan()
        #expect(upgradedPending.skills.isEmpty)
        #expect(try sandbox.modules()["pendingSkills"] as? [String] == [secondSelector])
        try expectObservation(
            upgradedPending, selector: firstSelector, permission: .approved, installed: false)
        try expectObservation(
            upgradedPending, selector: secondSelector, permission: .pending, installed: false)

        try sandbox.pnpm(["approve", secondSelector, "--yes"])
        let upgraded = try sandbox.scan()
        #expect(Set(upgraded.skills.map(\.name)) == ["shared-guide", "added-guide"])
        #expect(upgraded.skills.allSatisfy { $0.ownership == .pnpm })
        #expect(
            upgraded.skills.allSatisfy {
                $0.provenance.pnpm?.allSatisfy { $0.packageVersion == "2.0.0" } == true
            })
        try expectObservation(
            upgraded, selector: secondSelector, permission: .approved, installed: true)
        #expect(upgraded.pnpmObservations?.filter { $0.selector == secondSelector }.count == 1)
        try assertLinks(sandbox, count: 4)
        try sandbox.install()
        #expect(try sandbox.scan() == upgraded)
        try sandbox.assertReadOnly(upgraded)
    }

    private func denyAndRemovePackage(_ sandbox: PnpmRealSandbox) throws {
        try sandbox.pnpm(["approve", "!" + secondSelector, "--yes"])
        let denied = try sandbox.scan()
        #expect(denied.skills.isEmpty)
        #expect(try sandbox.modules()["linkedSkills"] == nil)
        #expect(try sandbox.modules()["pendingSkills"] == nil)
        try expectObservation(
            denied, selector: secondSelector, permission: .denied, installed: false)
        try sandbox.install()
        #expect(try sandbox.scan() == denied)

        try sandbox.pnpm(["remove", alpha, "--offline", "--ignore-scripts"])
        let removed = try sandbox.scan()
        #expect(removed.skills.isEmpty)
        #expect(removed.findings.isEmpty)
        try expectObservation(
            removed, selector: secondSelector, permission: .denied, installed: false)
        #expect(!FileManager.default.fileExists(atPath: sandbox.root + "/node_modules/" + alpha))
        #expect(!FileManager.default.fileExists(atPath: sandbox.root + "/skills-lock.json"))
    }

    @Test(
        "Two workspace importers normalize permissions and link into configured custom directories")
    func workspaceCustomDirectories() throws {
        let sandbox = try PnpmRealSandbox()
        try sandbox.package()
        try sandbox.project(dependencies: [:], directories: [])
        for importer in ["a", "b"] {
            try sandbox.project(
                "project/apps/" + importer,
                dependencies: [alpha: "file:../../../alpha-v1.tgz"], directories: [".claude/skills"]
            )
        }
        try sandbox.tree.file(
            "project/pnpm-workspace.yaml",
            contents: "packages:\n  - apps/*\nskills:\n  dirs:\n    - .special/agent-skills\n")
        try sandbox.install()
        let pending = try sandbox.scan()
        #expect(pending.skills.isEmpty)
        try expectObservation(
            pending, selector: firstSelector, permission: .pending, installed: false)
        try sandbox.pnpm(["approve", "--all", "--yes"])
        let report = try sandbox.scan()
        let skill = try #require(report.skills.first)
        #expect(report.skills.count == 1)
        #expect(skill.ownership == .pnpm)
        #expect(
            skill.placements.map(\.path) == [
                sandbox.root + "/.special/agent-skills/pnpm-@sukiru+real-alpha-guide"
            ])
        #expect(skill.provenance.pnpm?.first?.dependency == "file:../../../alpha-v1.tgz")
        #expect(
            try sandbox.modules()["linkedSkills"] as? [String] == [
                ".special/agent-skills/pnpm-@sukiru+real-alpha-guide"
            ])
        #expect(report.issues.isEmpty)
        for importer in ["a", "b"] {
            let dependency = sandbox.root + "/apps/" + importer + "/node_modules/" + alpha
            #expect(
                try FileManager.default.destinationOfSymbolicLink(atPath: dependency).contains(
                    ".pnpm/"))
            #expect(
                try FileManager.default.contentsOfDirectory(
                    atPath: sandbox.root + "/apps/" + importer + "/.claude/skills"
                ).isEmpty)
        }
        try expectObservation(
            report, selector: firstSelector, permission: .approved, installed: true)
        try sandbox.assertReadOnly(report)
    }

    @Test("Same frontmatter names retain separate package, installer and ownerless identities")
    func mixedSources() throws {
        let sandbox = try PnpmRealSandbox()
        try sandbox.package()
        try sandbox.package(name: "@sukiru/real-beta", archive: "beta-v1.tgz")
        try sandbox.project(dependencies: [
            alpha: "file:../alpha-v1.tgz", "@sukiru/real-beta": "file:../beta-v1.tgz"
        ])
        try sandbox.install()
        try sandbox.pnpm(["approve", "--all", "--yes"])
        try sandbox.tree.file(
            "project/.agents/skills/shared-guide/SKILL.md",
            contents: OwnershipBuilders.skillMD("shared-guide", variant: "Vercel copy."))
        try sandbox.tree.file(
            "project/skills-lock.json", contents: OwnershipBuilders.projectLock("shared-guide"))
        try sandbox.tree.file(
            "project/.claude/skills/manual-guide/SKILL.md",
            contents: OwnershipBuilders.skillMD("shared-guide", variant: "Manual copy."))
        let report = try sandbox.scan()
        let packages = report.skills.filter { $0.ownership == .pnpm }
        #expect(packages.count == 2)
        #expect(
            Set(packages.compactMap(\.packageQualifiedName)) == [
                "pnpm-@sukiru+real-alpha-guide", "pnpm-@sukiru+real-beta-guide"
            ])
        #expect(
            report.skills.contains { $0.ownership == .vercel && $0.packageQualifiedName == nil })
        #expect(report.findings.contains { $0.ruleID == HostNameCollisionRule.ruleID })
        let protectedPaths = Set(packages.flatMap { $0.placements.map(\.path) })
        #expect(
            report.findings.filter { $0.ruleID == "canonical-host-divergence" }.allSatisfy {
                $0.evidence.allSatisfy { !protectedPaths.contains($0.detail) }
            })
        try sandbox.assertReadOnly(report)
    }

    @Test("Missing targets, malformed native data and pnpm lookalikes never authorize mutation")
    func damagedEvidence() throws {
        let sandbox = try PnpmRealSandbox()
        try sandbox.package()
        try sandbox.project(dependencies: [alpha: "file:../alpha-v1.tgz"])
        try sandbox.install()
        try sandbox.pnpm(["approve", "--all", "--yes"])
        let installed = try sandbox.scan()
        let target = try #require(installed.skills.first?.provenance.pnpm?.first?.target)
        try FileManager.default.removeItem(atPath: target)
        let missing = try sandbox.scan()
        #expect(missing.skills.allSatisfy { $0.ownership != .pnpm && $0.isPnpmReadOnly })
        #expect(missing.issues.contains { $0.kind == IssueKind.pnpmUnverified })
        #expect(!missing.findings.contains { $0.ruleID == "broken-symlink" })
        try sandbox.assertReadOnly(missing)
        try sandbox.tree.file("project/node_modules/.modules.yaml", contents: "{")
        try sandbox.tree.file(
            "project/.claude/skills/pnpm-unrecorded-guide/SKILL.md",
            contents: OwnershipBuilders.skillMD("lookalike"))
        let malformed = try sandbox.scan()
        #expect(malformed.skills.allSatisfy { $0.ownership != .pnpm && $0.isPnpmReadOnly })
        #expect(malformed.issues.contains { $0.kind == IssueKind.pnpmUnverified })
        try sandbox.assertReadOnly(malformed)
    }

    private func expectObservation(
        _ report: ScanReport, selector: String, permission: PnpmObservation.Permission,
        installed: Bool
    ) throws {
        let observation = try #require(report.pnpmObservations?.first { $0.selector == selector })
        #expect(observation.permission == permission)
        #expect(observation.installed == installed)
        #expect(observation.projectRoot.hasSuffix("/project"))
    }

    private func assertLinks(_ sandbox: PnpmRealSandbox, count: Int) throws {
        let links = try #require(sandbox.modules()["linkedSkills"] as? [String])
        #expect(links.count == count)
        for link in links {
            let path = sandbox.root + "/" + link
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: path)
            #expect(destination.contains("node_modules/.pnpm/"))
            #expect(FileManager.default.fileExists(atPath: path + "/SKILL.md"))
        }
    }
}
