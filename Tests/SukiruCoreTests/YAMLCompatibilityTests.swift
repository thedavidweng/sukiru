import Foundation
import Testing

@testable import SukiruCore

@Suite("YAML migration compatibility boundary")
struct YAMLCompatibilityTests {
    @Test("Quoted keys preserve frontmatter and provenance", arguments: ["\"", "'"])
    func quotedFrontmatterKeys(quote: String) throws {
        let tree = try TempTree()
        let text = """
            ---
            \(quote)name\(quote): demo
            \(quote)description\(quote): "Quoted: mapping keys"
            \(quote)metadata\(quote):
              \(quote)internal\(quote): true
              \(quote)github-repo\(quote): https://github.com/owner/repo
              \(quote)github-pinned\(quote): "false"
            ---
            body
            """
        let path = try tree.file("SKILL.md", contents: text)
        let parsed = try FrontmatterParser().parse(skillFileAt: path).get()
        #expect(parsed.name == "demo")
        #expect(parsed.description == "Quoted: mapping keys")
        #expect(parsed.internal)
        #expect(parsed.githubProvenance?.pinnedRef == "false")
        #expect(FrontmatterParser.summary(ofSkillMD: text)?.name == parsed.name)
    }

    @Test(
        "Colons inside quoted keys are not mapping separators",
        arguments: [
            ("\"name: key\"", "name: key"),
            ("'owner''s: key'", "owner's: key"),
            ("\"escaped\\\": key\"", "escaped\": key")
        ])
    func quotedKeySeparators(source: String, key: String) throws {
        let value = try YAMLSubset.jsonValue(yaml: "\(source): value")
        #expect(value[key]?.stringValue == "value")
        #expect(try YAMLSubset.compose(yaml: source)?.string == key)
        #expect(try YAMLSubset.compose(yaml: source + " # comment: ignored")?.string == key)
    }

    @Test("Quoted scalar sequence items and root flow collections remain values")
    func quotedValues() throws {
        let sequence = try YAMLSubset.jsonValue(yaml: "- \"name: demo\"\n- 'owner''s: demo'")
        #expect(sequence.arrayValue?.compactMap(\.stringValue) == ["name: demo", "owner's: demo"])
        let mapping = try YAMLSubset.jsonValue(yaml: "{\"name\": \"demo: value\"}")
        #expect(mapping["name"]?.stringValue == "demo: value")
    }

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
