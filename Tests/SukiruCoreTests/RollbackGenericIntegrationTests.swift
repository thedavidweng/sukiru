import Foundation
import Testing

@testable import SukiruCore

@Suite("Explicit file bounds rollback", .serialized)
struct RollbackGenericIntegrationTests {
    @Test("Recorded post-state protects mixed file edits, deletions, additions and links")
    func mixedFileConflicts() throws {
        let tree = try TempTree()
        let root = try tree.dir("host")
        try tree.file("host/config", contents: "snapshot config")
        try tree.file("host/removed", contents: "snapshot removed")
        try tree.dir("host/empty")
        try tree.symlink("host/link", to: "original-target")
        let original = try TreeChecksum.manifest(root: root)
        let addedRoot = tree.path + "/batch-created"
        let script = try tree.executable("bin/mutate", contents: Self.mutationScript)
        let command = BatchCommand(
            argv: [script], displayString: script, owningCLI: .vercel,
            intent: "Mutate isolated host files", dangerFlags: [], warning: nil,
            captureRoots: [root, addedRoot])
        let environment = ExecutorTestSupport.environment(home: tree.path)
        let result = try CLIExecutor(environment: environment).execute(
            batch: ExecutorTestSupport.batch(commands: [command]),
            report: ExecutorTestSupport.userReport(home: tree.path))
        #expect(result.record.diff.entries.contains { $0.path == addedRoot })
        try tree.file("host/config", contents: "later config")
        try FileManager.default.removeItem(atPath: root + "/removed")
        try tree.file("host/later", contents: "later addition")
        try tree.file("batch-created/later", contents: "keep this")
        let cliEnvironment = CLIRunner.fixtureEnvironment(home: tree.path, roots: [])
        let refused = try CLIRunner.run(
            ["rollback", "--batch", "batch-1"], environment: cliEnvironment)
        #expect(refused.exitCode == 1)
        let preview = try #require(try refused.jsonObject())
        let conflicts = try #require(preview["conflicts"] as? [[String: Any]])
        #expect(
            Set(conflicts.compactMap { $0["kind"] as? String }) == ["modified", "deleted", "added"])
        #expect(
            conflicts.filter { $0["kind"] as? String == "added" }.allSatisfy {
                $0["canRestore"] as? Bool == false
            })
        let rollback = try CLIRunner.run(
            [
                "rollback", "--batch", "batch-1", "--preserve", root + "/config",
                "--restore", root + "/removed", "--preserve", root + "/later",
                "--preserve", addedRoot + "/later"
            ], environment: cliEnvironment)
        #expect(rollback.exitCode == 0)
        var expected = original
        let actual = try TreeChecksum.manifest(root: root)
        expected["config"] = actual["config"]
        expected["later"] = actual["later"]
        #expect(actual == expected)
        #expect(try String(contentsOfFile: root + "/config", encoding: .utf8) == "later config")
        #expect(try String(contentsOfFile: root + "/later", encoding: .utf8) == "later addition")
        #expect(!FileManager.default.fileExists(atPath: addedRoot + "/file"))
        #expect(try String(contentsOfFile: addedRoot + "/later", encoding: .utf8) == "keep this")
    }

    private static let mutationScript = """
        #!/bin/sh
        printf '%s' 'batch config' > "$HOME/host/config"
        printf '%s' 'batch removed' > "$HOME/host/removed"
        rm "$HOME/host/link"
        ln -s batch-target "$HOME/host/link"
        mkdir -p "$HOME/batch-created"
        printf '%s' 'batch addition' > "$HOME/batch-created/file"
        """

    @Test("Unreadable explicit file prevents commands from running")
    func captureFailurePreventsExecution() throws {
        let tree = try TempTree()
        let file = try tree.file("host/config", contents: "secret")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
        }
        let script = try tree.executable("bin/mutate", contents: "#!/bin/sh\ntouch \"$HOME/ran\"\n")
        let command = BatchCommand(
            argv: [script], displayString: script, owningCLI: .vercel,
            intent: "Must never run", dangerFlags: [], warning: nil, captureRoots: [file])
        let executor = CLIExecutor(environment: ExecutorTestSupport.environment(home: tree.path))
        #expect(throws: (any Error).self) {
            try executor.execute(
                batch: ExecutorTestSupport.batch(commands: [command]),
                report: ExecutorTestSupport.userReport(home: tree.path))
        }
        #expect(!FileManager.default.fileExists(atPath: tree.path + "/ran"))
    }
}
