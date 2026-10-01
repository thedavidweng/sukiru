import Foundation
import Testing

@testable import SukiruCore

/// Reader behavior against the checked-in fixture corpus: every malformed
/// `SKILL.md` variant becomes a `skill-md-invalid` issue while the healthy
/// sibling still parses, and the malformed/newer lock fixtures surface their
/// issues without ever crashing.
@Suite("Reader fixtures")
struct ReaderFixtureTests {
    private let parser = FrontmatterParser()

    private func skillFile(_ fixture: String, _ skill: String) -> String {
        FixturePaths.tree(fixture) + "/.agents/skills/\(skill)/SKILL.md"
    }

    @Test(
        "All six skillmd-invalid variants are issues; the healthy sibling parses",
        arguments: ["a", "b", "c", "d", "e", "f"]
    )
    func invalidVariants(variant: String) throws {
        let fixture = "skillmd-invalid-\(variant)"
        let result = parser.parse(skillFileAt: skillFile(fixture, "bad"))
        guard case .failure(let issue) = result else {
            Issue.record("\(fixture): bad SKILL.md unexpectedly parsed")
            return
        }
        #expect(issue.kind == IssueKind.skillMDInvalid)
        #expect(issue.path.hasSuffix("\(fixture)/.agents/skills/bad/SKILL.md"))
        #expect(!issue.message.isEmpty)

        let sibling = parser.parse(skillFileAt: skillFile(fixture, "healthy"))
        #expect(try #require(sibling.successValue).name == "healthy")
    }

    @Test("Variant failure reasons name the specific defect")
    func invalidVariantReasons() throws {
        // Appended pairwise: multi-line collection literals trip the repo's
        // conflicting swiftlint/swift-format trailing-comma gates.
        var reasons: [(String, String)] = []
        reasons.append(("a", "field `name`"))
        reasons.append(("b", "field `description`"))
        reasons.append(("c", "must be a YAML mapping"))
        reasons.append(("d", "must start with YAML frontmatter"))
        reasons.append(("e", "must start with YAML frontmatter"))
        reasons.append(("f", "YAML"))
        for (variant, reason) in reasons {
            let result = parser.parse(skillFileAt: skillFile("skillmd-invalid-\(variant)", "bad"))
            guard case .failure(let issue) = result else {
                Issue.record("skillmd-invalid-\(variant) unexpectedly parsed")
                continue
            }
            #expect(issue.message.contains(reason), "variant \(variant): \(issue.message)")
        }
    }

    @Test("The early-close fixture reproduces upstream's truncated-frontmatter outcome")
    func earlyCloseFixture() throws {
        let result = parser.parse(skillFileAt: skillFile("skillmd-early-close", "early"))
        guard case .failure(let issue) = result else {
            Issue.record("skillmd-early-close unexpectedly parsed")
            return
        }
        #expect(issue.kind == IssueKind.skillMDInvalid)
        #expect(issue.message.contains("required frontmatter field `name` is missing"))
        let sibling = parser.parse(skillFileAt: skillFile("skillmd-early-close", "healthy"))
        #expect(try #require(sibling.successValue).name == "healthy")
    }

    @Test("FIX-MALFORMED's newer global lock is an issue and still best-effort parsed")
    func malformedFixtureNewerLock() throws {
        let home = FixturePaths.tree("FIX-MALFORMED")
        let vars = ["SUKIRU_HOME": home]
        let reader = VercelLockReader(
            environment: SukiruEnvironment(reader: DictionaryEnvironmentReader(vars))
        )
        let result = reader.readGlobalLock()
        let issue = try #require(result.issue)
        #expect(issue.kind == IssueKind.lockVersionUnsupported)
        #expect(issue.path == HostPathResolver.join(home, ".agents/.skill-lock.json"))
        let lock = try #require(result.lock)
        #expect(lock.versionStatus == .newerThanSupported(found: 4, supported: 3))
        let entry = try #require(lock.entries["healthy"])
        #expect(entry.source == "thedavidweng/skills")
        #expect(entry.skillFolderHash == "3333333333333333333333333333333333333333")
        #expect(entry.extras["channel"] == .string("beta"))
        #expect(lock.extras["futureTopLevelKey"] == .string("preserved"))
    }

    @Test("FIX-MALFORMED's nameless SKILL.md is an issue; the healthy sibling parses")
    func malformedFixtureSkillMD() throws {
        let result = parser.parse(skillFileAt: skillFile("FIX-MALFORMED", "nameless"))
        guard case .failure(let issue) = result else {
            Issue.record("FIX-MALFORMED nameless SKILL.md unexpectedly parsed")
            return
        }
        #expect(issue.kind == IssueKind.skillMDInvalid)
        #expect(issue.message.contains("required frontmatter field `name` is missing"))
        #expect(
            try #require(
                parser.parse(skillFileAt: skillFile("FIX-MALFORMED", "healthy"))
                    .successValue
            ).name == "healthy")
    }

    @Test("FIX-GARBAGE's truncated lock is a ledger-unreadable issue")
    func garbageFixtureLock() throws {
        let home = FixturePaths.tree("FIX-GARBAGE")
        let vars = ["SUKIRU_HOME": home]
        let reader = VercelLockReader(
            environment: SukiruEnvironment(reader: DictionaryEnvironmentReader(vars))
        )
        let result = reader.readGlobalLock()
        let issue = try #require(result.issue)
        #expect(issue.kind == IssueKind.ledgerUnreadable)
        #expect(issue.path == HostPathResolver.join(home, ".agents/.skill-lock.json"))
        #expect(result.lock == nil)
    }
}
