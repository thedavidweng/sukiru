import Foundation
import Testing

@testable import SukiruCore

@Suite("Plugin executor effects consent")
struct PluginEffectsExecutorTests {
    @Test(
        "Reviewed batches cannot bypass effects consent at the shared executor",
        arguments: [DangerFlag.pluginRuntimeEffects, .backendStateChange])
    func effectsConsent(flag: DangerFlag) throws {
        let tree = try TempTree()
        let bin = try tree.dir("bin")
        let marker = tree.path + "/invoked"
        try tree.executable("bin/opencode", contents: "#!/bin/sh\ntouch '\(marker)'\n")
        let command = BatchCommand(
            argv: ["opencode", "plugin", "check"], displayString: "opencode plugin check",
            owningCLI: .opencode, intent: "Explicit runtime inspection", dangerFlags: [flag],
            warning: "External effects cannot be undone")
        let batch = ExecutorTestSupport.batch(commands: [command])
        let before = try TreeChecksum.manifest(root: tree.path)
        let executor = ExecutorTestSupport.makeExecutor(home: tree.path, shimPath: bin)
        do {
            _ = try executor.execute(
                batch: batch, report: ExecutorTestSupport.userReport(home: tree.path))
            Issue.record("Expected effects consent refusal")
        } catch let error as ExecutionError {
            #expect(error == .effectsNotApproved)
        }
        #expect(try TreeChecksum.manifest(root: tree.path) == before)
        #expect(!FileManager.default.fileExists(atPath: marker))
        let result = try executor.execute(
            batch: batch, report: ExecutorTestSupport.userReport(home: tree.path),
            effectsApproved: true)
        #expect(result.record.batchStatus == .succeeded)
        #expect(result.record.unrestorableEffects == ["External effects cannot be undone"])
        #expect(FileManager.default.fileExists(atPath: marker))
    }
}
