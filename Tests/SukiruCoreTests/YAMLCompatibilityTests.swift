import Foundation
import Testing

@testable import SukiruCore

@Suite("YAML migration compatibility boundary")
struct YAMLCompatibilityTests {
    @Test("Anchors, explicit tags, flow mappings, escapes and unknown nested values survive")
    func structuredFrontmatter() throws {
        let tree = try TempTree()
        let text = """
            ---
            name: &name !!str 123
            description: *name
            metadata: {internal: true, github-repo: 'https://github.com/owner/repo', github-pinned: !!str false}
            unknown: [{nested: [null, 42, true]}, "escaped\\nline"]
            ---
            body
            """
        let path = try tree.file("SKILL.md", contents: text)
        let parsed = try FrontmatterParser().parse(skillFileAt: path).get()
        #expect(parsed.name == "123")
        #expect(parsed.description == "123")
        #expect(parsed.internal)
        #expect(parsed.githubProvenance?.pinnedRef == "false")
        #expect(FrontmatterParser.summary(ofSkillMD: text)?.name == parsed.name)
    }

    @Test(
        "Folded and literal block scalars preserve YAML whitespace",
        arguments: [
            (">-", "first second"), ("|-", "first\nsecond")
        ])
    func blocks(style: String, expected: String) throws {
        let tree = try TempTree()
        let path = try tree.file(
            "SKILL.md", contents: "---\nname: demo\ndescription: \(style)\n  first\n  second\n---\n"
        )
        let parsed = try FrontmatterParser().parse(skillFileAt: path).get()
        #expect(parsed.description == expected)
    }
}
