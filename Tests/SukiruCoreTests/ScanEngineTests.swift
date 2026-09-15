import Foundation
import Testing

@testable import SukiruCore

@Suite("ScanEngine skeleton report")
struct ScanEngineTests {
    @Test("Emits an empty schema-valid report for a valid home")
    func emptyReport() throws {
        let vars = ["SUKIRU_HOME": "/fixture"]
        let env = SukiruEnvironment(reader: DictionaryEnvironmentReader(vars))
        let probe = StubFileSystem(existing: ["/fixture"])
        let engine = ScanEngine(environment: env, fileSystem: probe)
        let report = try engine.scan(ScanRequest())
        #expect(report.schemaVersion == 1)
        #expect(report.workspaces.isEmpty)
        #expect(report.skills.isEmpty)
        #expect(report.findings.isEmpty)
        #expect(report.issues.isEmpty)
    }

    @Test("Throws when SUKIRU_HOME is set but missing")
    func missingHome() {
        let env = SukiruEnvironment(reader: DictionaryEnvironmentReader(["SUKIRU_HOME": "/gone"]))
        let engine = ScanEngine(environment: env, fileSystem: StubFileSystem(existing: []))
        #expect(throws: FatalEnvironmentProblem.sukiruHomeMissing(path: "/gone")) {
            try engine.scan(ScanRequest())
        }
    }

    @Test("JSON output is deterministic and carries the D18 top-level keys")
    func deterministicJSON() throws {
        let report = ScanReport()
        let first = try report.jsonData()
        let second = try report.jsonData()
        #expect(first == second)

        let object = try JSONSerialization.jsonObject(with: first) as? [String: Any]
        let keys = Set((object ?? [:]).keys)
        #expect(keys == ["schemaVersion", "workspaces", "skills", "findings", "issues"])
    }
}
