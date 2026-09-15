import Foundation
import Testing

@testable import SukiruCore

/// HealthAnalyzer detection rules against the checked-in fixture corpus
/// (VAL-SCAN-023…030, plus the D3 severity sweep VAL-SCAN-052 and the
/// zero-findings baselines VAL-SCAN-041).
///
/// Origin boundaries (library/read-side-porting.md): `broken-symlink` comes
/// from InventoryScanner; `ambiguous-name`, `double-booked`, and
/// `files-without-lock` come from OwnershipResolver. HealthAnalyzer owns
/// `cross-host-duplicate`, `symlink-authenticity`, `vercel-lock-drift`,
/// `lock-without-files`, `canonical-host-divergence`,
/// `dangerous-removal-surface`, and the `lock-version-unsupported`
/// environment anomaly — and must never re-emit the other components' rules.
@Suite("HealthAnalyzer against checked-in fixtures")
struct HealthAnalyzerFixtureTests {
    /// All evidence details of one kind, in emission order.
    private func details(_ finding: Finding, _ kind: String) -> [String] {
        finding.evidence.filter { $0.kind == kind }.map(\.detail)
    }

    private func finding(
        _ report: ScanReport, _ ruleID: String, _ skillName: String
    ) throws -> Finding {
        try #require(
            report.findings.first { $0.ruleID == ruleID && $0.skillName == skillName })
    }

    // MARK: - VAL-SCAN-023: alias subtype

    @Test("alias-link-mode: alias-subtype duplicate at info severity, shared canonical path")
    func aliasLinkMode() throws {
        let report = try OwnershipBuilders.scan(fixture: "alias-link-mode")
        let finding = try self.finding(report, "cross-host-duplicate", "demo")
        #expect(finding.severity == .info)
        #expect(details(finding, "subtype") == ["alias"])

        let demo = try #require(report.skills.first { $0.name == "demo" })
        let canonical = try #require(demo.placements.compactMap(\.canonicalPath).first)
        #expect(details(finding, "canonicalPath") == [canonical])
        #expect(
            Set(details(finding, "memberPath")) == Set(demo.placements.map(\.path)),
            "one memberPath per placement")
        #expect(
            !report.findings.contains {
                $0.ruleID == "cross-host-duplicate" && $0.skillName == "demo"
                    && $0.evidence.contains { $0.detail == "exact" }
            },
            "an alias group must never be misclassified as exact")
    }

    // MARK: - VAL-SCAN-024 / 025: exact and divergent subtypes

    @Test("FIX-DUPLICATES: exact-demo is an exact duplicate (warning, both paths, shared hash)")
    func duplicatesExact() throws {
        let tree = FixturePaths.tree("FIX-DUPLICATES")
        let report = try OwnershipBuilders.scan(fixture: "FIX-DUPLICATES")
        let finding = try self.finding(report, "cross-host-duplicate", "exact-demo")
        #expect(finding.severity == .warning)
        #expect(details(finding, "subtype") == ["exact"])
        #expect(
            Set(details(finding, "memberPath"))
                == [tree + "/.claude/skills/exact-demo", tree + "/.codex/skills/exact-demo"])
        let hashes = details(finding, "contentHash")
        #expect(hashes.count == 1)
        let skill = try #require(report.skills.first { $0.name == "exact-demo" })
        #expect(hashes.first == skill.placements.first?.contentHash)
    }

    @Test("FIX-DUPLICATES: div-demo is a divergent duplicate (warning, both paths, both hashes)")
    func duplicatesDivergent() throws {
        let tree = FixturePaths.tree("FIX-DUPLICATES")
        let report = try OwnershipBuilders.scan(fixture: "FIX-DUPLICATES")
        let finding = try self.finding(report, "cross-host-duplicate", "div-demo")
        #expect(finding.severity == .warning)
        #expect(details(finding, "subtype") == ["divergent"])
        #expect(
            Set(details(finding, "memberPath"))
                == [tree + "/.claude/skills/div-demo", tree + "/.codex/skills/div-demo"])
        let evidenceHashes = Set(details(finding, "contentHash"))
        #expect(evidenceHashes.count == 2, "divergent evidence carries BOTH content hashes")
        let skill = try #require(report.skills.first { $0.name == "div-demo" })
        #expect(evidenceHashes == Set(skill.placements.compactMap(\.contentHash)))

        // The alias group in the same tree stays an info-level alias.
        let alias = try self.finding(report, "cross-host-duplicate", "alias-demo")
        #expect(alias.severity == .info)
        #expect(details(alias, "subtype") == ["alias"])
    }

    // MARK: - VAL-SCAN-026: symlink-authenticity impostor

    @Test("impostor-copy: the physical host copy is flagged with its canonical link target")
    func impostorCopy() throws {
        let tree = FixturePaths.tree("impostor-copy")
        let report = try OwnershipBuilders.scan(fixture: "impostor-copy")
        let finding = try self.finding(report, "symlink-authenticity", "tool")
        #expect(details(finding, "impostorPath") == [tree + "/.claude/skills/tool"])
        #expect(details(finding, "canonicalPath") == [tree + "/.agents/skills/tool"])
    }

    // MARK: - symlink-authenticity known false positive (accepted v1 limitation)

    @Test("FIX-USER-SCOPE-COPY-MODE: the heuristic flags a LEGITIMATE user-scope copy-mode install")
    func userScopeCopyModeFalsePositive() throws {
        // PINNED CURRENT BEHAVIOR — see the fixture's EXPECTATION.md. The
        // symlink-authenticity heuristic cannot distinguish a legitimate
        // user-scope copy-mode install from a rotted link-mode one because
        // the global lock records no install-mode bit. Both physical host
        // copies are flagged as impostors even though nothing is wrong.
        // A future fix must flip these expectations deliberately.
        let tree = FixturePaths.tree("FIX-USER-SCOPE-COPY-MODE")
        let report = try OwnershipBuilders.scan(fixture: "FIX-USER-SCOPE-COPY-MODE")
        let findings = report.findings.filter {
            $0.ruleID == "symlink-authenticity" && $0.skillName == "copy-tool"
        }
        #expect(findings.count == 2, "one false-positive finding per physical host copy")
        #expect(findings.allSatisfy { $0.severity == .warning })
        let impostors = findings.flatMap { details($0, "impostorPath") }.sorted()
        #expect(
            impostors
                == [tree + "/.claude/skills/copy-tool", tree + "/.cursor/skills/copy-tool"])
        #expect(
            findings.allSatisfy {
                details($0, "canonicalPath") == [tree + "/.agents/skills/copy-tool"]
            })
        // Everything else about the shape is healthy and unambiguous.
        let skill = try #require(report.skills.first { $0.name == "copy-tool" })
        #expect(skill.ownership == .vercel)
        #expect(!skill.ambiguous)
        #expect(!report.findings.contains { $0.ruleID == "vercel-lock-drift" })
        #expect(!report.findings.contains { $0.ruleID == "lock-without-files" })
    }

    // MARK: - VAL-SCAN-027: vercel-lock-drift

    @Test("lock-drift: project drift carries lock/entry/hash evidence; global scope stays silent")
    func lockDrift() throws {
        let tree = FixturePaths.tree("lock-drift")
        let report = try OwnershipBuilders.scanSplitFixture("lock-drift")
        let driftFindings = report.findings.filter { $0.ruleID == "vercel-lock-drift" }
        let finding = try #require(driftFindings.first)
        #expect(driftFindings.count == 1, "exactly one drift finding in the tree")
        #expect(finding.severity == .action)
        #expect(finding.skillName == "drifted")
        #expect(details(finding, "lockPath") == [tree + "/proj/skills-lock.json"])
        #expect(details(finding, "entryKey") == ["drifted"])

        let reader = VercelLockReader(
            environment: SukiruEnvironment(
                reader: DictionaryEnvironmentReader(
                    ["SUKIRU_HOME": tree + "/.home", "SUKIRU_ROOTS": tree + "/proj"])))
        let stored = try #require(
            reader.readProjectLock(projectRoot: tree + "/proj").lock?.entries["drifted"]?
                .computedHash)
        #expect(details(finding, "expectedHash") == [stored])
        let skill = try #require(report.skills.first { $0.name == "drifted" })
        let recomputed = try #require(skill.placements.first?.contentHash)
        #expect(details(finding, "actualHash") == [recomputed])
        #expect(stored != recomputed, "the fixture must actually be drifted")

        // The global-scope entry (git tree SHA) is by-design never compared.
        #expect(
            !report.findings.contains {
                $0.ruleID == "vercel-lock-drift" && $0.skillName == "global-ctl"
            })
    }

    // MARK: - VAL-SCAN-028: lock-without-files

    @Test("FIX-LOCK-NO-FILES: ghost is a lock-without-files finding and never a healthy placement")
    func lockWithoutFiles() throws {
        let tree = FixturePaths.tree("FIX-LOCK-NO-FILES")
        let report = try OwnershipBuilders.scan(fixture: "FIX-LOCK-NO-FILES")
        let finding = try self.finding(report, "lock-without-files", "ghost")
        #expect(finding.severity == .action)
        #expect(details(finding, "lockPath") == [tree + "/.agents/.skill-lock.json"])
        #expect(details(finding, "entryKey") == ["ghost"])
        #expect(
            !report.skills.contains { $0.name == "ghost" },
            "a ledger claim alone conjures no skill")
    }

    // MARK: - VAL-SCAN-029: canonical-host-divergence

    @Test("divergence-canonical: one source identity, both paths, both content hashes")
    func canonicalHostDivergence() throws {
        let tree = FixturePaths.tree("divergence-canonical")
        let report = try OwnershipBuilders.scanSplitFixture("divergence-canonical")
        let finding = try self.finding(report, "canonical-host-divergence", "web-tool")
        #expect(finding.severity == .action)
        #expect(details(finding, "canonicalPath") == [tree + "/proj/.agents/skills/web-tool"])
        #expect(details(finding, "hostPath") == [tree + "/proj/.claude/skills/web-tool"])
        #expect(
            details(finding, "sourceIdentity")
                == ["thedavidweng/skills|github|.agents/skills/web-tool/SKILL.md|"])
        let evidenceHashes = Set(details(finding, "contentHash"))
        #expect(evidenceHashes.count == 2, "both content hashes named")
        let skill = try #require(report.skills.first { $0.name == "web-tool" })
        #expect(evidenceHashes == Set(skill.placements.compactMap(\.contentHash)))
    }

    // MARK: - VAL-SCAN-030: dangerous-removal-surface

    @Test("FIX-DANGER: advisories exactly on the gh-owned and ownerless skills, never vercel-owned")
    func dangerousRemovalSurface() throws {
        let tree = FixturePaths.tree("FIX-DANGER")
        let report = try OwnershipBuilders.scan(fixture: "FIX-DANGER")
        let advisories = report.findings.filter { $0.ruleID == "dangerous-removal-surface" }
        #expect(Set(advisories.compactMap(\.skillName)) == ["gh-tool", "orphan"])
        #expect(advisories.allSatisfy { $0.severity == .action })
        #expect(
            !advisories.contains { $0.skillName == "vercel-ctl" },
            "a vercel-locked name's removal is ledger-consistent")

        let ghTool = try #require(advisories.first { $0.skillName == "gh-tool" })
        #expect(details(ghTool, "skillName") == ["gh-tool"])
        #expect(details(ghTool, "placementPath") == [tree + "/.claude/skills/gh-tool"])
        #expect(details(ghTool, "ownership") == ["github"])

        let orphan = try #require(advisories.first { $0.skillName == "orphan" })
        #expect(details(orphan, "placementPath") == [tree + "/.claude/skills/orphan"])
        #expect(details(orphan, "ownership") == ["ownerless"])
    }

    // MARK: - Environment anomaly: lock-version-unsupported finding

    @Test("FIX-MALFORMED: newer lock version surfaces a finding with version evidence")
    func newerLockVersionFinding() throws {
        let tree = FixturePaths.tree("FIX-MALFORMED")
        let report = try OwnershipBuilders.scan(fixture: "FIX-MALFORMED")
        let finding = try #require(
            report.findings.first { $0.ruleID == "lock-version-unsupported" })
        #expect(finding.severity == .warning)
        #expect(finding.skillName == nil)
        #expect(finding.workspaceID == "user")
        #expect(details(finding, "lockPath") == [tree + "/.agents/.skill-lock.json"])
        #expect(details(finding, "foundVersion") == ["4"])
        #expect(details(finding, "supportedVersion") == ["3"])
        // Best-effort parse still inventories the healthy sibling.
        #expect(report.skills.contains { $0.name == "healthy" })
    }

    @Test("lock-version-old: an older incompatible lock is an issue, never a finding")
    func olderLockVersionIssueOnly() throws {
        let tree = FixturePaths.tree("lock-version-old")
        let report = try OwnershipBuilders.scanSplitFixture("lock-version-old")
        #expect(!report.findings.contains { $0.ruleID == "lock-version-unsupported" })
        let issue = try #require(
            report.issues.first { $0.kind == IssueKind.lockVersionUnsupported })
        #expect(issue.path == tree + "/proj/skills-lock.json")
    }

    // MARK: - Zero-findings baselines (VAL-SCAN-041 shape)

    @Test("FIX-CLEAN and FIX-EMPTY produce zero findings", arguments: ["FIX-CLEAN", "FIX-EMPTY"])
    func cleanTreesZeroFindings(fixture: String) throws {
        let report = try OwnershipBuilders.scan(fixture: fixture)
        #expect(report.findings.isEmpty, "findings: \(report.findings.map(\.ruleID))")
    }

    @Test("symlink-mode: the only finding is the info-level alias duplicate")
    func symlinkModeOnlyAliasFinding() throws {
        let report = try OwnershipBuilders.scan(fixture: "symlink-mode")
        let finding = try self.finding(report, "cross-host-duplicate", "tool")
        #expect(finding.severity == .info)
        #expect(details(finding, "subtype") == ["alias"])
        #expect(
            report.findings.allSatisfy {
                $0.ruleID == "cross-host-duplicate" && $0.severity == .info
            },
            "healthy link mode yields no actionable findings: \(report.findings.map(\.ruleID))")
    }

    @Test("clean-copy-mode: exact duplicate fires; no drift, no removal advisory (lock-claimed)")
    func cleanCopyMode() throws {
        let report = try OwnershipBuilders.scanSplitFixture("clean-copy-mode")
        let finding = try self.finding(report, "cross-host-duplicate", "web-tool")
        #expect(finding.severity == .warning)
        #expect(details(finding, "subtype") == ["exact"])
        #expect(!report.findings.contains { $0.ruleID == "vercel-lock-drift" })
        #expect(!report.findings.contains { $0.ruleID == "dangerous-removal-surface" })
        #expect(!report.findings.contains { $0.ruleID == "symlink-authenticity" })
    }

    // MARK: - Consequential check

    @Test("lock-without-files coincides with the absence of a healthy placement for the name")
    func lockWithoutFilesConsequential() throws {
        // Sweep the hand-built corpus: every lock-without-files finding names a
        // skill with NO non-broken placement in that scope, and every lock
        // entry without a healthy placement is backed by a finding.
        // Space-listed to avoid a multi-line collection literal (repo lint
        // gates conflict on those).
        let fixtures =
            "FIX-CLEAN FIX-LOCK-NO-FILES FIX-DANGER own-vercel own-double impostor-copy"
            .split(separator: " ").map(String.init) + ["FIX-MALFORMED"]
        for fixture in fixtures {
            let report = try OwnershipBuilders.scan(fixture: fixture)
            let findings = report.findings.filter { $0.ruleID == "lock-without-files" }
            for finding in findings {
                let name = try #require(finding.skillName)
                let healthy = report.skills.contains {
                    $0.name == name
                        && $0.placements.contains { $0.kind != .brokenSymlink }
                }
                #expect(!healthy, "\(fixture): \(name) has a healthy placement")
            }
        }
    }
}
