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

    @Test(
        "Compact JSON objects retain every value kind",
        arguments: [
            #"{"openclaw":{"requires":{"anyBins":["python3"]}}}"#,
            #"{"integer":42,"negative":-7,"fraction":1.25,"exponent":1e-3,"text":"hello: world","#
                + #""true":true,"false":false,"nothing":null}"#,
            #"{"nested":{"empty":{}},"sequence":[1,"two",true,null,[],{"three":3}],"escaped\"key":"quoted\"value"}"#
        ])
    func compactJSONValues(source: String) throws {
        let expected = try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
        #expect(try YAMLSubset.jsonValue(yaml: source) == expected)
    }

    @Test("Single-quoted flow keys also permit adjacent values")
    func compactSingleQuotedKeys() throws {
        let parsed = try YAMLSubset.jsonValue(
            yaml: "{'count':42,'text':'value','nested':{'enabled':true}}")
        #expect(parsed["count"] == .int(42))
        #expect(parsed["text"] == .string("value"))
        #expect(parsed["nested"]?["enabled"] == .bool(true))
    }

    @Test("Compact metadata survives full frontmatter parsing and summary")
    func compactMetadata() throws {
        let tree = try TempTree()
        let metadata =
            #"{"openclaw":{"requires":{"anyBins":["python3"]}},"internal":true,"#
            + #""github-repo":"https://github.com/owner/repo","github-pinned":"main","count":42,"optional":null}"#
        let text = """
            ---
            name: demo
            description: Compact metadata
            metadata: \(metadata)
            ---
            body
            """
        let path = try tree.file("SKILL.md", contents: text)
        let parsed = try FrontmatterParser().parse(skillFileAt: path).get()
        #expect(parsed.name == "demo")
        #expect(parsed.description == "Compact metadata")
        #expect(parsed.internal)
        #expect(parsed.githubProvenance?.pinnedRef == "main")
        #expect(FrontmatterParser.summary(ofSkillMD: text)?.name == parsed.name)
        #expect(FrontmatterParser.summary(ofSkillMD: text)?.description == parsed.description)
    }

    @Test(
        "Plain YAML keys still require separators",
        arguments: [
            "{plain:42}", "{plain:true}", "{plain:null}", "{plain:\"text\"}",
            "{plain:{nested: value}}", "{plain:[1, 2]}"
        ])
    func plainKeySeparation(source: String) {
        #expect(throws: YAMLError.self) {
            try YAMLSubset.jsonValue(yaml: source)
        }
    }

    @Test("Plain scalar colons and separated plain keys preserve their meaning")
    func plainScalarColons() throws {
        let parsed = try YAMLSubset.jsonValue(
            yaml: "{url: https://example.com/path, text: owner:value, nested: {count: 42}}")
        #expect(parsed["url"] == .string("https://example.com/path"))
        #expect(parsed["text"] == .string("owner:value"))
        #expect(parsed["nested"]?["count"] == .int(42))
    }

    @Test("Malformed compact metadata reports the parser diagnostic")
    func invalidCompactMetadata() throws {
        let tree = try TempTree()
        let text = """
            ---
            name: demo
            description: Invalid metadata
            metadata: {"broken" 1}
            ---
            """
        let path = try tree.file("SKILL.md", contents: text)
        guard case .failure(let issue) = FrontmatterParser().parse(skillFileAt: path) else {
            Issue.record("Malformed compact metadata unexpectedly parsed")
            return
        }
        #expect(issue.kind == IssueKind.skillMDInvalid)
        #expect(issue.message.contains("expected `:` in flow mapping"))
        #expect(FrontmatterParser.summary(ofSkillMD: text) == nil)
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
