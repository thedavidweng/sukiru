import Foundation
import Testing

@testable import SukiruCore

/// `SKILL.md` frontmatter parsing.
///
/// The parser reproduces upstream `split_frontmatter` byte-for-byte: a strict
/// start delimiter (`---\n`/`---\r\n` at byte 0, no BOM tolerance), and the
/// FIRST `\n---` as the closing delimiter — including the trap where a `---`
/// inside a multi-line YAML string truncates the frontmatter early. Malformed
/// input always becomes an `Issue`, never a thrown error or crash.
@Suite("Frontmatter parser")
struct FrontmatterParserTests {
    private let parser = FrontmatterParser()

    private func write(_ tree: TempTree, _ contents: String) throws -> String {
        try tree.file("skills/demo/SKILL.md", contents: contents)
    }

    private func failure(of result: Result<SkillMetadata, ScanIssue>) -> ScanIssue? {
        if case .failure(let issue) = result { return issue }
        return nil
    }

    private func metadata(_ result: Result<SkillMetadata, ScanIssue>) -> SkillMetadata? {
        if case .success(let metadata) = result { return metadata }
        return nil
    }

    @Test("Valid frontmatter parses name, description, defaults")
    func validFrontmatter() throws {
        let tree = try TempTree()
        let path = try write(tree, "---\nname: demo\ndescription: A demo skill.\n---\n\n# demo\n")
        let parsed = try #require(metadata(parser.parse(skillFileAt: path)))
        #expect(parsed.name == "demo")
        #expect(parsed.description == "A demo skill.")
        #expect(!parsed.internal)
        #expect(parsed.githubProvenance == nil)
        #expect(parsed.skillFilePath == path)
    }

    @Test("CRLF delimiters are accepted")
    func crlfDelimiters() throws {
        let tree = try TempTree()
        let path = try write(
            tree, "---\r\nname: demo\r\ndescription: CRLF skill.\r\n---\r\nbody\r\n")
        let parsed = try #require(metadata(parser.parse(skillFileAt: path)))
        #expect(parsed.name == "demo")
        #expect(parsed.description == "CRLF skill.")
    }

    @Test("Missing start delimiter is an issue")
    func missingStartDelimiter() throws {
        let tree = try TempTree()
        let path = try write(tree, "# demo\n\nname: demo\ndescription: no delimiters\n")
        let issue = try #require(failure(of: parser.parse(skillFileAt: path)))
        #expect(issue.kind == IssueKind.skillMDInvalid)
        #expect(issue.path == path)
        #expect(issue.message.contains("must start with YAML frontmatter"))
    }

    @Test("A UTF-8 BOM before the delimiter is not tolerated")
    func bomNotTolerated() throws {
        let tree = try TempTree()
        let path = try write(tree, "\u{FEFF}---\nname: demo\ndescription: BOM file.\n---\n")
        let issue = try #require(failure(of: parser.parse(skillFileAt: path)))
        #expect(issue.kind == IssueKind.skillMDInvalid)
        #expect(issue.message.contains("must start with YAML frontmatter"))
    }

    @Test("A leading blank line before the delimiter is not tolerated")
    func leadingBlankLine() throws {
        let tree = try TempTree()
        let path = try write(tree, "\n---\nname: demo\ndescription: late delimiter.\n---\n")
        #expect(failure(of: parser.parse(skillFileAt: path)) != nil)
    }

    @Test("A missing closing delimiter is an issue")
    func missingClosingDelimiter() throws {
        let tree = try TempTree()
        let path = try write(tree, "---\nname: demo\ndescription: never closed\n")
        let issue = try #require(failure(of: parser.parse(skillFileAt: path)))
        #expect(issue.kind == IssueKind.skillMDInvalid)
        #expect(issue.message.contains("must start with YAML frontmatter"))
    }

    @Test("Non-mapping frontmatter is an issue")
    func nonMappingFrontmatter() throws {
        let tree = try TempTree()
        let path = try write(tree, "---\n- item one\n- item two\n---\n\n# demo\n")
        let issue = try #require(failure(of: parser.parse(skillFileAt: path)))
        #expect(issue.kind == IssueKind.skillMDInvalid)
        #expect(issue.message.contains("must be a YAML mapping"))
    }

    @Test("Empty frontmatter has no closing delimiter (upstream parity)")
    func emptyFrontmatter() throws {
        // "---\n---\n": after the start delimiter the remainder is "---\n",
        // which contains no "\n---" — upstream reports the generic delimiter
        // error, not a mapping error.
        let tree = try TempTree()
        let path = try write(tree, "---\n---\n")
        let issue = try #require(failure(of: parser.parse(skillFileAt: path)))
        #expect(issue.kind == IssueKind.skillMDInvalid)
        #expect(issue.message.contains("must start with YAML frontmatter"))
    }

    @Test("Delimited but empty frontmatter is not a mapping")
    func delimitedEmptyFrontmatter() throws {
        let tree = try TempTree()
        let path = try write(tree, "---\n\n---\n")
        let issue = try #require(failure(of: parser.parse(skillFileAt: path)))
        #expect(issue.kind == IssueKind.skillMDInvalid)
        #expect(issue.message.contains("must be a YAML mapping"))
    }

    @Test("A YAML syntax error is an issue, never a crash")
    func yamlSyntaxError() throws {
        let tree = try TempTree()
        let path = try write(tree, "---\nname: [unterminated\ndescription: broken\n---\n")
        let issue = try #require(failure(of: parser.parse(skillFileAt: path)))
        #expect(issue.kind == IssueKind.skillMDInvalid)
        #expect(!issue.message.isEmpty)
    }

    @Test("Missing, blank, and non-string names are all the upstream missing-field error")
    func invalidNames() throws {
        let tree = try TempTree()
        let missing = try write(tree, "---\ndescription: no name here.\n---\n")
        let blank = try tree.file("b/SKILL.md", contents: "---\nname: \"\"\ndescription: d\n---\n")
        let numeric = try tree.file("c/SKILL.md", contents: "---\nname: 123\ndescription: d\n---\n")
        for path in [missing, blank, numeric] {
            let issue = try #require(failure(of: parser.parse(skillFileAt: path)))
            #expect(issue.message.contains("required frontmatter field `name` is missing"))
        }
    }

    @Test("Missing, blank, and non-string descriptions are the missing-field error")
    func invalidDescriptions() throws {
        let tree = try TempTree()
        let missing = try write(tree, "---\nname: demo\n---\n")
        let blank = try tree.file(
            "b/SKILL.md", contents: "---\nname: demo\ndescription: \"\"\n---\n")
        let numeric = try tree.file(
            "c/SKILL.md", contents: "---\nname: demo\ndescription: 7\n---\n")
        for path in [missing, blank, numeric] {
            let issue = try #require(failure(of: parser.parse(skillFileAt: path)))
            #expect(issue.message.contains("required frontmatter field `description` is missing"))
        }
    }

    @Test("Whitespace-padded fields are trimmed")
    func fieldsAreTrimmed() throws {
        let tree = try TempTree()
        let path = try write(tree, "---\nname: \"  demo  \"\ndescription: \"  padded.  \"\n---\n")
        let parsed = try #require(metadata(parser.parse(skillFileAt: path)))
        #expect(parsed.name == "demo")
        #expect(parsed.description == "padded.")
    }

    @Test("metadata.internal is read only as a real bool")
    func internalFlag() throws {
        let tree = try TempTree()
        let yaml = "---\nname: demo\ndescription: d\nmetadata:\n  internal: true\n---\n"
        let path = try write(tree, yaml)
        #expect(try #require(metadata(parser.parse(skillFileAt: path))).internal)
    }

    @Test("internal defaults to false and tolerates odd shapes")
    func internalFlagDefaults() throws {
        let tree = try TempTree()
        let quoted = "---\nname: demo\ndescription: d\nmetadata:\n  internal: \"true\"\n---\n"
        let nonMapping = "---\nname: demo\ndescription: d\nmetadata: not-a-map\n---\n"
        let nullMetadata = "---\nname: demo\ndescription: d\nmetadata: null\n---\n"
        for (offset, yaml) in [quoted, nonMapping, nullMetadata].enumerated() {
            let path = try tree.file("case\(offset)/SKILL.md", contents: yaml)
            let parsed = try #require(metadata(parser.parse(skillFileAt: path)))
            #expect(!parsed.internal, "case \(offset) must yield internal == false")
        }
    }

    @Test("Unknown keys are tolerated")
    func unknownKeysTolerated() throws {
        let tree = try TempTree()
        let yaml =
            "---\nname: demo\ndescription: d\nfuture-key: [1, 2]\nother: {nested: yes}\n---\n"
        let path = try write(tree, yaml)
        #expect(metadata(parser.parse(skillFileAt: path)) != nil)
    }

    @Test("A --- line inside a multi-line string truncates the frontmatter (upstream parity)")
    func earlyClosingTruncates() throws {
        let tree = try TempTree()
        let yaml = "---\ndescription: |\n  line one\n  line two\n---\nname: orphaned\n---\n"
        let path = try write(tree, yaml)
        let issue = try #require(failure(of: parser.parse(skillFileAt: path)))
        #expect(issue.kind == IssueKind.skillMDInvalid)
        #expect(issue.message.contains("required frontmatter field `name` is missing"))
    }

    @Test("The closing delimiter is not line-anchored (---foo also closes)")
    func closingNotLineAnchored() throws {
        let tree = try TempTree()
        let path = try write(tree, "---\nname: demo\n---foo\ndescription: orphaned\n---\n")
        let issue = try #require(failure(of: parser.parse(skillFileAt: path)))
        #expect(issue.message.contains("required frontmatter field `description` is missing"))
    }

    @Test("An unreadable SKILL.md is an issue, never a crash")
    func unreadableFile() throws {
        let tree = try TempTree()
        let missing = HostPathResolver.join(tree.path, "nowhere/SKILL.md")
        let issue = try #require(failure(of: parser.parse(skillFileAt: missing)))
        #expect(issue.kind == IssueKind.skillMDUnreadable)
        #expect(issue.path == missing)
    }
}
