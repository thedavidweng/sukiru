import Foundation
import Testing

@testable import SukiruCore

@Suite("Explicit file bounds rollback", .serialized)
struct RollbackGenericIntegrationTests {
    @Test(
        "Incomplete post-state keeps history and recovers only chosen snapshot files",
        arguments: [false, true])
    func incompleteEvidenceRecovery(replaceWithDirectory: Bool) throws {
        let tree = try TempTree()
        let root = try tree.dir("host")
        let config = try tree.file("host/config", contents: "snapshot config")
        let kept = try tree.file("host/kept", contents: "snapshot kept")
        let script = try tree.executable(
            "bin/mutate",
            contents: """
                #!/bin/sh
                printf '%s' 'batch config' > "$HOME/host/config"
                printf '%s' 'batch kept' > "$HOME/host/kept"
                mkfifo "$HOME/host/unsupported"
                printf '%s' 'unknown addition' > "$HOME/host/added"
                """)
        let command = BatchCommand(
            argv: [script], displayString: script, owningCLI: .vercel,
            intent: "Create unsupported post-state in isolated fixture", dangerFlags: [],
            warning: nil,
            captureRoots: [root])
        let environment = ExecutorTestSupport.environment(home: tree.path)
        #expect(throws: (any Error).self) {
            try CLIExecutor(environment: environment).execute(
                batch: ExecutorTestSupport.batch(commands: [command]),
                report: ExecutorTestSupport.userReport(home: tree.path))
        }
        let recordPath =
            tree.path + "/Library/Application Support/Sukiru/executions/batch-1/record.json"
        let record = try JSONDecoder().decode(
            ExecutionRecord.self, from: Data(contentsOf: URL(fileURLWithPath: recordPath)))
        #expect(record.commands.first?.status == .succeeded)
        #expect(record.fileEvidenceFailure?.contains("unsupported") == true)
        let snapshot =
            tree.path + "/Library/Application Support/Sukiru/snapshots/" + record.snapshotID
        #expect(!FileManager.default.fileExists(atPath: snapshot + "/after.json"))
        if replaceWithDirectory {
            try FileManager.default.removeItem(atPath: config)
            try tree.file("host/config/unknown", contents: "must survive")
        }
        let cliEnvironment = CLIRunner.fixtureEnvironment(home: tree.path, roots: [])
        let refused = try CLIRunner.run(
            ["rollback", "--batch", "batch-1"], environment: cliEnvironment)
        #expect(refused.exitCode == 1)
        let preview = try #require(try refused.jsonObject())
        #expect(preview["fileEvidenceFailure"] as? String == record.fileEvidenceFailure)
        let conflicts = try #require(preview["conflicts"] as? [[String: Any]])
        #expect(Set(conflicts.compactMap { $0["path"] as? String }) == [config, kept])
        let recovered = try CLIRunner.run(
            ["rollback", "--batch", "batch-1", "--restore", config, "--preserve", kept],
            environment: cliEnvironment)
        try verifyRecovery(
            recovered, root: root, config: config, kept: kept, replacement: replaceWithDirectory)
    }

    private func verifyRecovery(
        _ recovered: CLIRunner.Result, root: String, config: String, kept: String, replacement: Bool
    ) throws {
        #expect(recovered.exitCode == 0)
        #expect(try String(contentsOfFile: kept, encoding: .utf8) == "batch kept")
        #expect(try String(contentsOfFile: root + "/added", encoding: .utf8) == "unknown addition")
        #expect(DefaultFileSystemProbe().entryKind(atPath: root + "/unsupported") != nil)
        if replacement {
            #expect(
                try String(contentsOfFile: config + "/unknown", encoding: .utf8) == "must survive")
            let result = try #require(try recovered.jsonObject())
            let items = try #require(result["items"] as? [[String: Any]])
            #expect(
                items.contains {
                    $0["path"] as? String == config
                        && $0["category"] as? String == "unrestorable-with-reason"
                })
        } else {
            #expect(try String(contentsOfFile: config, encoding: .utf8) == "snapshot config")
        }
    }

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
