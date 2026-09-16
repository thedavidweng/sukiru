import Foundation

@testable import SukiruCore

/// Shared builders for the CLIExecutor suites: reviewed batches with explicit
/// commands, minimal scan inputs, and POSIX shim scripts (env/tty dumps,
/// order logs, failures, timeouts, oversized output).
///
/// Every shim is a `#!/bin/sh` script made executable in a per-test `bin/`
/// dir that becomes the executor's injected PATH — no process-global `setenv`
/// is ever needed, so suites stay parallel-safe.
enum ExecutorTestSupport {
    /// A `SUKIRU_HOME`-overridden environment rooted at `home`.
    static func environment(home: String) -> SukiruEnvironment {
        SukiruEnvironment(reader: DictionaryEnvironmentReader(["SUKIRU_HOME": home]))
    }

    /// A batch command with full argv and a non-empty intent.
    static func command(
        _ argv: [String],
        cli: OwningCLI,
        workingDirectory: String? = nil
    ) -> BatchCommand {
        BatchCommand(
            argv: argv,
            displayString: BatchCommand.display(for: argv),
            owningCLI: cli,
            intent: "test command",
            dangerFlags: [],
            warning: nil,
            workingDirectory: workingDirectory)
    }

    /// A batch in the given status carrying the given commands.
    static func batch(
        commands: [BatchCommand],
        refs: [FindingRef] = [],
        status: BatchStatus = .reviewed,
        id: String = "batch-1"
    ) -> CommandBatch {
        CommandBatch(
            id: id,
            createdAt: "2026-09-16T00:00:00Z",
            findingRefs: refs,
            decisions: [],
            commands: commands,
            snapshotID: nil,
            status: status)
    }

    /// Minimal report: one user-scope workspace rooted at `<home>/.agents/skills`.
    static func userReport(home: String) -> ScanReport {
        let workspace = Workspace(
            id: "user", kind: .user, root: home + "/.agents/skills", installed: true)
        return ScanReport(workspaces: [workspace])
    }

    /// An executor whose CLI lookup and spawn PATH is the shim dir plus the
    /// system tools — deterministic and offline.
    static func makeExecutor(
        home: String,
        shimPath: String,
        timeout: TimeInterval = 30,
        token: String? = nil
    ) -> CLIExecutor {
        CLIExecutor(
            environment: environment(home: home),
            commandTimeout: timeout,
            pathOverride: shimPath + ":/usr/bin:/bin",
            ghToken: token)
    }

    // MARK: - shim scripts (absolute paths are baked in; temp paths have no spaces)

    /// Logs `start-$3` / `end-$3` around a short sleep — any concurrency
    /// interleaves the markers and fails the order assertion.
    static func orderLogShim(logPath: String) -> String {
        """
        #!/bin/sh
        echo "start-$3" >> "\(logPath)"
        sleep 0.2
        echo "end-$3" >> "\(logPath)"
        """
    }

    /// Touches `ran-$3` first, then fails with a known stderr marker when
    /// invoked for `failName` — proves both the failure capture and that the
    /// next command never started.
    static func failOnShim(treePath: String, failName: String) -> String {
        """
        #!/bin/sh
        touch "\(treePath)/ran-$3"
        if [ "$3" = "\(failName)" ]; then
          echo "boom-stderr-marker" >&2
          exit 3
        fi
        echo "ok-$3"
        """
    }

    /// Prints known markers to both streams and exits 0.
    static var echoShim: String {
        """
        #!/bin/sh
        echo "std-out-marker-$3"
        echo "std-err-marker-$3" >&2
        """
    }

    /// Emits ~200 KB of numbered lines ending in a well-formed end marker —
    /// three times the 65 536-byte pipe-truncation cliff.
    static var bigOutputShim: String {
        """
        #!/bin/sh
        i=0
        while [ "$i" -lt 8000 ]; do
          echo "sukiru-big-output-line-$i"
          i=$((i + 1))
        done
        echo "SUKIRU-END-MARKER"
        """
    }

    /// Dumps the contracted environment + tty state to `dumpPath` (GH_TOKEN
    /// only ever as a presence marker, never the value).
    static func envDumpShim(dumpPath: String) -> String {
        """
        #!/bin/sh
        {
          echo "HOME=$HOME"
          echo "CI=$CI"
          echo "SKILLS_TELEMETRY=$SKILLS_TELEMETRY"
          if [ -n "${GH_TOKEN:-}" ]; then echo "GH_TOKEN=present"; else echo "GH_TOKEN=absent"; fi
          if [ -t 0 ]; then echo "STDIN_TTY=yes"; else echo "STDIN_TTY=no"; fi
          if [ -t 1 ]; then echo "STDOUT_TTY=yes"; else echo "STDOUT_TTY=no"; fi
          echo "PWD=$(pwd -P)"
        } >> "\(dumpPath)"
        echo "env-dump-ok"
        """
    }

    /// Records its pid, then sleeps far beyond any test timeout via `exec`
    /// (the sleeper IS the direct child, so termination leaves no orphan).
    static func sleepShim(pidPath: String) -> String {
        """
        #!/bin/sh
        echo $$ > "\(pidPath)"
        exec sleep 60
        """
    }

    /// Parses a `KEY=value` shim dump.
    static func parseDump(_ path: String) throws -> [String: String] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                result[String(parts[0])] = String(parts[1])
            }
        }
        return result
    }

    /// Recursive byte search: whether ANY regular file under `root` contains
    /// `needle` (the GH_TOKEN persistence grep, VAL-REPAIR-054).
    static func treeContains(_ root: String, needle: String) -> Bool {
        let needleData = Data(needle.utf8)
        guard let enumerator = FileManager.default.enumerator(atPath: root) else {
            return false
        }
        for case let relative as String in enumerator {
            guard let data = FileManager.default.contents(atPath: root + "/" + relative) else {
                continue
            }
            if data.range(of: needleData) != nil {
                return true
            }
        }
        return false
    }

    /// A pid that is certainly dead (a reaped `/usr/bin/true` child; there
    /// is no `/bin/true` on macOS 26+).
    static func deadPID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }
}
