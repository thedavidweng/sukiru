import Foundation
import Testing

@testable import SukiruCore

/// The D12 decisions-file vocabulary parser (VAL-REPAIR-052): strict shape
/// validation with naming messages, before any finding lookups happen.
@Suite("DecisionsFile parsing and vocabulary validation")
struct DecisionsFileTests {
    private func parse(_ json: String) -> Result<[DecisionEntry], DecisionsFileError> {
        DecisionsFile.parse(Data(json.utf8))
    }

    private func message(_ result: Result<[DecisionEntry], DecisionsFileError>) throws -> String {
        switch result {
        case .success(let entries):
            Issue.record("expected failure, parsed \(entries.count) entries")
            return ""
        case .failure(let error):
            return error.message
        }
    }

    // MARK: - valid files

    @Test("every vocabulary action parses, in a single mixed file")
    func validVocabulary() throws {
        let json = """
            {
              "f-update": {"action": "update"},
              "f-leave": {"action": "leave"},
              "f-cleanup": {"action": "cleanup"},
              "f-arb": {"action": "arbitrate", "choice": "keep-vercel"},
              "f-adopt": {"action": "adopt", "choice": {"repo": "acme/tools", "path": "skills/x"}}
            }
            """
        let entries = try parse(json).get()
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.findingID, $0) })
        #expect(entries.count == 5)
        #expect(byID["f-update"]?.action == .update)
        #expect(byID["f-leave"]?.choice == nil)
        #expect(byID["f-arb"]?.choice == .keepVercel)
        #expect(byID["f-adopt"]?.choice == .adoptSource(repo: "acme/tools", path: "skills/x"))
    }

    @Test("an empty decisions object parses to zero entries")
    func emptyFile() throws {
        #expect(try parse("{}").get().isEmpty)
    }

    // MARK: - malformed shapes

    @Test("non-JSON input and a top-level array are rejected")
    func malformedTopLevel() throws {
        #expect(try message(parse("not json")).contains("not valid JSON"))
        #expect(try message(parse("[1, 2]")).contains("object"))
    }

    @Test("entry must be an object with an action string")
    func entryShape() throws {
        #expect(try message(parse("{\"f\": \"update\"}")).contains("f"))
        #expect(try message(parse("{\"f\": {}}")).contains("action"))
        #expect(try message(parse("{\"f\": {\"action\": 3}}")).contains("action"))
    }

    @Test("unknown action is rejected naming the valid vocabulary")
    func unknownAction() throws {
        let text = try message(parse("{\"f\": {\"action\": \"purge\"}}"))
        #expect(text.contains("purge"))
        #expect(text.contains("update"))
        #expect(text.contains("arbitrate"))
        #expect(text.contains("adopt"))
        #expect(text.contains("cleanup"))
        #expect(text.contains("leave"))
    }

    @Test("unknown keys inside a decision entry are rejected by name")
    func unknownKey() throws {
        let text = try message(parse("{\"f\": {\"action\": \"update\", \"agressive\": true}}"))
        #expect(text.contains("agressive"))
        #expect(text.contains("f"))
    }

    // MARK: - choice rules per action

    @Test("arbitrate requires choice keep-vercel or keep-github (VAL-REPAIR-052)")
    func arbitrateChoice() throws {
        #expect(try message(parse("{\"f\": {\"action\": \"arbitrate\"}}")).contains("choice"))
        let badJSON = "{\"f\": {\"action\": \"arbitrate\", \"choice\": \"keep-neither\"}}"
        let bad = try message(parse(badJSON))
        #expect(bad.contains("keep-neither"))
        #expect(bad.contains("keep-vercel"))
        #expect(bad.contains("keep-github"))
        let object = "{\"f\": {\"action\": \"arbitrate\", \"choice\": {\"repo\": \"a/b\"}}}"
        #expect(try message(parse(object)).contains("keep-vercel"))
    }

    @Test("adopt requires repo and path, repo in owner/repo shape (D11)")
    func adoptChoice() throws {
        #expect(try message(parse("{\"f\": {\"action\": \"adopt\"}}")).contains("repo"))
        let noPath = "{\"f\": {\"action\": \"adopt\", \"choice\": {\"repo\": \"acme/tools\"}}}"
        #expect(try message(parse(noPath)).contains("path"))
        let badChoice = "{\"repo\": \"noslash\", \"path\": \"p\"}"
        let badRepo = "{\"f\": {\"action\": \"adopt\", \"choice\": \(badChoice)}}"
        #expect(try message(parse(badRepo)).contains("owner/repo"))
        let extraChoice = "{\"repo\": \"a/b\", \"path\": \"p\", \"x\": 1}"
        let extra = "{\"f\": {\"action\": \"adopt\", \"choice\": \(extraChoice)}}"
        #expect(try message(parse(extra)).contains("x"))
    }

    @Test("update, cleanup, and leave take no choice")
    func unexpectedChoice() throws {
        for action in ["update", "cleanup", "leave"] {
            let json = "{\"f\": {\"action\": \"\(action)\", \"choice\": \"keep-vercel\"}}"
            let text = try message(parse(json))
            #expect(text.contains(action))
            #expect(text.contains("choice"))
        }
    }
}
