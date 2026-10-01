import Foundation
import Testing

@testable import SukiruCore

/// Unknown lock fields captured by `VercelLockReader` into
/// `extras` must reach the wire — entry-level extras ride
/// `Skill.provenance.vercel.extras`; top-level lock extras ride the report's
/// `lockExtras`, keyed by the scope's ownership-bucket/canonical workspace id
/// (`user` / `project:<root>`). Both are additive wire keys: they appear only when
/// a lock actually carries unknown keys, with original values, sorted keys.
@Suite("Lock extras wire surfacing")
struct LockExtrasWireTests {

    @Test("lock-unknown-fields: entry extras surface on the skill's vercel provenance")
    func entryExtrasSurfaced() throws {
        let report = try OwnershipBuilders.scan(fixture: "lock-unknown-fields")
        let skill = try #require(report.skills.first { $0.name == "known-tool" })
        #expect(skill.ownership == .vercel)
        let vercel = try #require(skill.provenance.vercel)
        #expect(vercel.extras?["channel"] == .string("beta"))
        #expect(vercel.extras?["priority"] == .int(7))
    }

    @Test("lock-unknown-fields: top-level lock extras surface under the scope key")
    func topLevelExtrasSurfaced() throws {
        let report = try OwnershipBuilders.scan(fixture: "lock-unknown-fields")
        let userExtras = try #require(report.lockExtras?["user"])
        #expect(userExtras["futureTopLevelKey"] == .string("preserved"))
        #expect(userExtras["experimental"] == .object(["flag": .bool(true)]))
        // Known top-level keys never leak into extras.
        #expect(userExtras["skills"] == nil)
        #expect(userExtras["dismissed"] == nil)
    }

    @Test("FIX-MALFORMED: extras surface alongside the version-unsupported issue")
    func malformedExtrasSurfaced() throws {
        let report = try OwnershipBuilders.scan(fixture: "FIX-MALFORMED")
        #expect(report.issues.contains { $0.kind == IssueKind.lockVersionUnsupported })
        let healthy = try #require(report.skills.first { $0.name == "healthy" })
        #expect(healthy.provenance.vercel?.extras?["channel"] == .string("beta"))
        #expect(report.lockExtras?["user"]?["futureTopLevelKey"] == .string("preserved"))
    }

    @Test("Extras reach the encoded JSON with original values")
    func extrasOnTheWire() throws {
        let report = try OwnershipBuilders.scan(fixture: "lock-unknown-fields")
        let data = try report.jsonData()
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let lockExtras = try #require(object["lockExtras"] as? [String: Any])
        let userExtras = try #require(lockExtras["user"] as? [String: Any])
        #expect(userExtras["futureTopLevelKey"] as? String == "preserved")
        let experimental = try #require(userExtras["experimental"] as? [String: Any])
        #expect(experimental["flag"] as? Bool == true)

        let skills = try #require(object["skills"] as? [[String: Any]])
        let knownTool = try #require(skills.first { ($0["name"] as? String) == "known-tool" })
        let provenance = try #require(knownTool["provenance"] as? [String: Any])
        let vercel = try #require(provenance["vercel"] as? [String: Any])
        let extras = try #require(vercel["extras"] as? [String: Any])
        #expect(extras["channel"] as? String == "beta")
        #expect(extras["priority"] as? Int == 7)
    }

    @Test("Clean locks add no extras keys (additive, omit-when-empty)")
    func cleanReportOmitsExtras() throws {
        let report = try OwnershipBuilders.scan(fixture: "FIX-CLEAN")
        #expect(report.lockExtras == nil)
        #expect(report.skills.allSatisfy { $0.provenance.vercel?.extras == nil })
        let data = try report.jsonData()
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["lockExtras"] == nil)
        let skills = try #require(object["skills"] as? [[String: Any]])
        for skill in skills {
            let provenance = try #require(skill["provenance"] as? [String: Any])
            if let vercel = provenance["vercel"] as? [String: Any] {
                #expect(vercel["extras"] == nil)
            }
        }
    }

    @Test("Reports with extras are byte-identical across identical scans")
    func deterministicWithExtras() throws {
        let first = try OwnershipBuilders.scan(fixture: "lock-unknown-fields").jsonData()
        let second = try OwnershipBuilders.scan(fixture: "lock-unknown-fields").jsonData()
        #expect(first == second)
    }
}
