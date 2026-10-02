import Foundation
import Testing

@testable import SukiruCore

/// The field-level signature that tells a global-lock entry gh created and
/// last wrote (its companion record) from one `npx skills` wrote:
/// whole-second UTC timestamps (`time.RFC3339`) and only gh's fields, versus
/// `toISOString()` milliseconds and npx's wider field set. Evidence:
/// docs/collision-matrix.md, second 2026-10-02 follow-up.
@Suite("gh companion lock signature")
struct GitHubCompanionSignatureTests {
    // MARK: gh companion signature

    /// One global lock with a single entry decoded from `entryJSON`.
    private func entry(_ entryJSON: String) throws -> VercelLockEntry {
        let json = """
            { "version": 3, "skills": { "tool": \(entryJSON) } }
            """
        let lock = try #require(VercelLockReader.decode(Data(json.utf8), scope: .global))
        return try #require(lock.entries["tool"])
    }

    /// An entry shaped like gh 2.102.0's `lockfile.RecordInstall` output
    /// (verbatim field set, whole-second UTC stamps), with per-test
    /// overrides; a nil value omits the field.
    private func ghEntry(_ overrides: [String: String?] = [:]) -> String {
        var fields: [(String, String?)] = [
            ("source", "\"anthropics/skills\""),
            ("sourceType", "\"github\""),
            ("sourceUrl", "\"https://github.com/anthropics/skills.git\""),
            ("skillPath", "\"skills/xlsx/SKILL.md\""),
            ("skillFolderHash", "\"fe6471cc9b5b97aae0b576ccb92ffd9b0207589d\""),
            ("installedAt", "\"2026-10-02T20:43:32Z\""),
            ("updatedAt", "\"2026-10-02T20:43:32Z\"")
        ]
        for (key, value) in overrides {
            if let index = fields.firstIndex(where: { $0.0 == key }) {
                fields[index] = (key, value)
            } else {
                fields.append((key, value))
            }
        }
        let body = fields.compactMap { key, value in
            value.map { "\"\(key)\": \($0)" }
        }.joined(separator: ", ")
        return "{ \(body) }"
    }

    @Test("gh's own entry shape is a companion record")
    func companionSignatureMatches() throws {
        #expect(try entry(ghEntry()).isGitHubCompanion)
        #expect(
            try entry(ghEntry(["pinnedRef": "\"v1.2.3\""])).isGitHubCompanion,
            "a pinned gh install keeps the signature")
    }

    @Test("npx field shapes are never companion records")
    func companionSignatureRejects() throws {
        let milliseconds: [String: String?] = [
            "installedAt": "\"2026-10-02T20:43:11.330Z\"",
            "updatedAt": "\"2026-10-02T20:43:32.330Z\""
        ]
        #expect(
            try !entry(ghEntry(milliseconds)).isGitHubCompanion,
            "npx stamps toISOString(), always with milliseconds")

        #expect(
            try !entry(ghEntry(["installedAt": milliseconds["installedAt"]!]))
                .isGitHubCompanion,
            "gh rewriting an npx entry keeps npx's installedAt: still a Vercel claim")

        let nonGitHubFields: [String: String?] = [
            "ref": "\"main\"",
            "pluginName": "\"document-skills\"",
            "computedHash": "\"abc\"",
            "sourceBaseUrl": "\"https://skills.sh\"",
            "wellKnownDigest": "\"abc\"",
            "unknownKey": "\"x\""
        ]
        for (key, value) in nonGitHubFields {
            #expect(
                try !entry(ghEntry([key: value])).isGitHubCompanion,
                "\(key) is not a field gh's entry struct can hold")
        }

        #expect(
            try !entry(ghEntry(["sourceType": "\"well-known\""])).isGitHubCompanion)
        #expect(try !entry(ghEntry(["updatedAt": nil])).isGitHubCompanion)
    }

}
