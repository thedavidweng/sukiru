import Foundation
import Testing

/// A temporary home with one host shim on PATH. The shim answers version and
/// help probes, logs every other invocation, and runs `onRun` for it, so a
/// test observes the exact argv Sukiru dispatched and its file effects.
struct PluginHostFixture {
    let tree: TempTree
    let home: String
    let roots: [String]
    let host: String

    init(
        host: String, version: String, help: String = "--json --scope --global --force",
        projects: [String] = [], onRun: String = ""
    ) throws {
        let tree = try TempTree()
        self.tree = tree
        home = try tree.dir("home")
        roots = try projects.map { try tree.dir($0) }
        self.host = host
        try tree.executable(
            "bin/" + (host == "cursor" ? "agent" : host),
            contents: """
                #!/bin/sh
                case "$*" in
                --version) echo '\(version)';;
                *--help*) echo '\(help)';;
                *) echo "$*" >> '\(tree.path)/invocations'
                \(onRun);;
                esac
                """)
    }

    var environment: [String: String] {
        CLIRunner.fixtureEnvironment(
            home: home, roots: roots, path: tree.path + "/bin:/usr/bin:/bin")
    }

    /// Every argv the shim received outside version and help probes.
    var invocations: [String] {
        let text = try? String(contentsOfFile: tree.path + "/invocations", encoding: .utf8)
        return text?.split(separator: "\n").map(String.init) ?? []
    }

    func request(
        _ action: String, _ target: String, scope: String = "user", root: String? = nil
    ) -> [String: String] {
        [
            "host": host, "action": action, "target": target, "scope": scope,
            "scopeRoot": root ?? home
        ]
    }

    func plan(_ requests: [[String: String]]) throws -> CLIRunner.Result {
        try CLIRunner.run(
            ["plugins", "plan", "--requests", try write(requests)], environment: environment)
    }

    func execute(
        _ requests: [[String: String]], flags: [String] = ["--yes", "--confirm-dangerous"]
    ) throws -> CLIRunner.Result {
        try CLIRunner.run(
            ["plugins", "execute", "--requests", try write(requests)] + flags,
            environment: environment)
    }

    func rollback(_ result: CLIRunner.Result) throws -> CLIRunner.Result {
        let record = try #require(try result.jsonObject())
        let batchID = try #require(record["batchID"] as? String)
        return try CLIRunner.run(
            ["rollback", "--yes", "--batch", batchID], environment: environment)
    }

    private func write(_ requests: [[String: String]]) throws -> String {
        let path = tree.path + "/requests-\(UUID().uuidString).json"
        try JSONSerialization.data(withJSONObject: requests).write(to: URL(fileURLWithPath: path))
        return path
    }
}

extension CLIRunner.Result {
    /// The planned commands of a `plugins plan` or dry-run result.
    func plannedCommands() throws -> [[String: Any]] {
        let record = try #require(try jsonObject())
        let batch = try #require(record["batch"] as? [String: Any])
        return try #require(batch["commands"] as? [[String: Any]])
    }

    func instructions() throws -> [String] {
        try #require(try jsonObject())["instructions"] as? [String] ?? []
    }

    var stderrText: String { String(bytes: stderr, encoding: .utf8) ?? "" }
}
