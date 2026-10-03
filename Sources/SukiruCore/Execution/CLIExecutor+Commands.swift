import Foundation

/// Per-command dispatch, record construction, and the workspace-boundary
/// preflight — the per-command execution detail of `CLIExecutor`.
extension CLIExecutor {
    /// The captured output files for one command (`cmd-NN.stdout/.stderr`).
    struct OutputFiles {
        let stdout: String
        let stderr: String
    }

    /// The terminal verdict of one command: status, exit code, failure
    /// kind, and human-readable diagnostics bundled to keep `finished`
    /// small.
    struct CommandVerdict {
        let status: CommandExecutionStatus
        let exitCode: Int32?
        let failureKind: CommandFailureKind?
        let diagnostics: String?
    }

    // MARK: - per-command dispatch

    func runCLICommand(
        _ command: BatchCommand, index: Int, recordDir: String
    ) -> CommandExecution {
        let files = createOutputFiles(index: index, recordDir: recordDir)
        let started = Date()
        guard let executable = resolveExecutable(command.argv[0]) else {
            let missing = CommandVerdict(
                status: .failed, exitCode: nil, failureKind: .executableMissing,
                diagnostics: "required CLI '\(command.argv[0])' was not found on PATH; "
                    + "install it (or restore PATH) and retry the batch")
            return finished(
                command, index: index, files: files, started: started, verdict: missing)
        }
        let invocation = SubprocessInvocation(
            argv: command.argv,
            executablePath: executable.path,
            environment: childEnvironment(for: command),
            workingDirectory: command.workingDirectory,
            stdoutPath: files.stdout,
            stderrPath: files.stderr)
        do {
            let outcome = try Subprocess.run(invocation, timeout: commandTimeout)
            return mapOutcome(
                outcome, command: command, index: index, files: files, started: started)
        } catch {
            let spawn = CommandVerdict(
                status: .failed, exitCode: nil, failureKind: .spawnFailed,
                diagnostics: "could not spawn '\(executable.path)': \(error)")
            return finished(
                command, index: index, files: files, started: started, verdict: spawn)
        }
    }

    /// A flagged direct file operation (ADR-0007), always preflight-checked
    /// for shape and bounds (see `preflightFileOperations`).
    func runFileOperation(
        _ command: BatchCommand, index: Int, recordDir: String
    ) -> CommandExecution {
        let files = createOutputFiles(index: index, recordDir: recordDir)
        let started = Date()
        do {
            guard let operation = FileOperation(argv: command.argv) else {
                throw FileOperationError("unsupported file operation")
            }
            try operation.perform()
        } catch {
            let failure = CommandVerdict(
                status: .failed, exitCode: 1, failureKind: .fileOperationFailed,
                diagnostics: "\(command.argv[1]) failed: \(error.localizedDescription)")
            return finished(
                command, index: index, files: files, started: started, verdict: failure)
        }
        let success = CommandVerdict(
            status: .succeeded, exitCode: 0, failureKind: nil, diagnostics: nil)
        return finished(
            command, index: index, files: files, started: started, verdict: success)
    }

    /// Maps a reaped subprocess outcome onto the terminal-state vocabulary.
    private func mapOutcome(
        _ outcome: SubprocessOutcome, command: BatchCommand, index: Int,
        files: OutputFiles, started: Date
    ) -> CommandExecution {
        let outcomeVerdict = verdict(of: outcome, stderrFile: files.stderr)
        return finished(
            command, index: index, files: files, started: started, verdict: outcomeVerdict)
    }

    /// The verdict for one subprocess outcome (timeout wins over the raw
    /// termination; a non-zero exit carries the stderr tail).
    private func verdict(of outcome: SubprocessOutcome, stderrFile: String) -> CommandVerdict {
        if outcome.timedOut {
            return CommandVerdict(
                status: .timedOut, exitCode: nil, failureKind: .timeout,
                diagnostics: "timed out after \(Self.milliseconds(commandTimeout))s; "
                    + "the process group was terminated (SIGTERM, then SIGKILL)")
        }
        switch outcome.termination {
        case .exited(0):
            return CommandVerdict(
                status: .succeeded, exitCode: 0, failureKind: nil, diagnostics: nil)
        case .exited(let code):
            var diagnostics = "exit code \(code)"
            if let tail = stderrTail(stderrFile) {
                diagnostics += "; stderr (tail): \(tail)"
            }
            return CommandVerdict(
                status: .failed, exitCode: code, failureKind: .nonZeroExit,
                diagnostics: diagnostics)
        case .signaled(let signal):
            return CommandVerdict(
                status: .failed, exitCode: nil, failureKind: .signaled,
                diagnostics: "terminated by signal \(signal)")
        case nil:
            return CommandVerdict(
                status: .failed, exitCode: nil, failureKind: .spawnFailed,
                diagnostics: "the process state could not be determined")
        }
    }

    // MARK: - record construction

    /// Stamps a command record: argv byte-equals the reviewed batch's argv,
    /// with captured-file paths and fractional-second
    /// timing.
    func finished(
        _ command: BatchCommand, index: Int, files: OutputFiles, started: Date,
        verdict: CommandVerdict
    ) -> CommandExecution {
        let ended = Date()
        return CommandExecution(
            index: index,
            argv: command.argv,
            displayString: command.displayString,
            owningCLI: command.owningCLI,
            intent: command.intent,
            status: verdict.status,
            exitCode: verdict.exitCode,
            failureKind: verdict.failureKind,
            diagnostics: verdict.diagnostics,
            stdoutFile: files.stdout,
            stderrFile: files.stderr,
            startedAt: Self.timestamp(started),
            endedAt: Self.timestamp(ended),
            durationSeconds: Self.milliseconds(ended.timeIntervalSince(started)))
    }

    /// A command the batch never reached (stop-on-first-failure).
    static func notRun(_ command: BatchCommand, index: Int) -> CommandExecution {
        bareRecord(command, index: index, status: .notRun, failureKind: nil, diagnostics: nil)
    }

    /// A preflight-refused file operation: failed without running, so no
    /// output files exist.
    static func preflightFailure(
        _ command: BatchCommand, index: Int, kind: CommandFailureKind
    ) -> CommandExecution {
        let diagnostics: String
        if kind == .outOfBounds {
            let path = command.argv.last ?? ""
            diagnostics =
                "path '\(path)' is outside the batch's workspace roots; "
                + "refusing to mutate it"
        } else {
            diagnostics = "unsupported file operation: \(command.displayString)"
        }
        return bareRecord(
            command, index: index, status: .failed, failureKind: kind,
            diagnostics: diagnostics)
    }

    /// A record for a command that produced no output files (never ran or
    /// refused at preflight).
    private static func bareRecord(
        _ command: BatchCommand, index: Int, status: CommandExecutionStatus,
        failureKind: CommandFailureKind?, diagnostics: String?
    ) -> CommandExecution {
        CommandExecution(
            index: index,
            argv: command.argv,
            displayString: command.displayString,
            owningCLI: command.owningCLI,
            intent: command.intent,
            status: status,
            exitCode: nil,
            failureKind: failureKind,
            diagnostics: diagnostics,
            stdoutFile: nil,
            stderrFile: nil,
            startedAt: nil,
            endedAt: nil,
            durationSeconds: nil)
    }

    /// Creates the (empty) capture files before spawning, so the paths in
    /// the record always exist.
    func createOutputFiles(index: Int, recordDir: String) -> OutputFiles {
        let stem = HostPathResolver.join(recordDir, String(format: "cmd-%02d", index))
        let files = OutputFiles(stdout: stem + ".stdout", stderr: stem + ".stderr")
        FileManager.default.createFile(atPath: files.stdout, contents: nil)
        FileManager.default.createFile(atPath: files.stderr, contents: nil)
        return files
    }

    // MARK: - workspace boundary

    /// Validates every direct-file-operation command BEFORE anything runs:
    /// argv shape (a known `FileOperation`) and the workspace boundary for
    /// every path it touches. Violators are failed without executing.
    func preflightFileOperations(
        _ commands: [BatchCommand], bounds: [String]
    ) -> [Int: CommandFailureKind] {
        var violations: [Int: CommandFailureKind] = [:]
        for (index, command) in commands.enumerated() where command.owningCLI == .file {
            guard let operation = FileOperation(argv: command.argv) else {
                violations[index] = .fileOperationFailed
                continue
            }
            let operationBounds: [String]
            if case .movePlugin = operation {
                operationBounds = bounds + (command.captureRoots ?? [])
            } else {
                operationBounds = bounds
            }
            if !operation.paths.allSatisfy({ isInBounds($0, bounds: operationBounds) }) {
                violations[index] = .outOfBounds
            }
        }
        return violations
    }

    /// The raw and realpath-resolved roots of every workspace inside the
    /// batch's touched ownership buckets.
    func workspaceBounds(batch: CommandBatch, report: ScanReport) -> [String] {
        let buckets = Set(batch.findingRefs.map(\.workspaceID))
        let probe = DefaultFileSystemProbe()
        var roots = Set<String>()
        for workspace in report.workspaces where buckets.contains(bucket(of: workspace)) {
            roots.insert(workspace.root)
            if let resolved = probe.resolvedPath(atPath: workspace.root) {
                roots.insert(resolved)
            }
        }
        return roots.sorted()
    }

    /// The ownership bucket a workspace belongs to: `user` for user scope,
    /// `project:<root>` for project workspaces (host variants carry `#host`).
    private func bucket(of workspace: Workspace) -> String {
        guard workspace.kind == .project else {
            return "user"
        }
        let rest = workspace.id.dropFirst("project:".count)
        let root = rest.split(separator: "#").first.map(String.init) ?? ""
        return "project:" + root
    }

    private func isInBounds(_ path: String, bounds: [String]) -> Bool {
        let probe = DefaultFileSystemProbe()
        var candidates = [path]
        if let resolved = probe.resolvedPath(atPath: path) {
            candidates.append(resolved)
        }
        return bounds.contains { root in
            candidates.contains { $0 == root || $0.hasPrefix(root + "/") }
        }
    }

    // MARK: - formatting

    static func timestamp(_ date: Date) -> String {
        // Fresh per call: ISO8601DateFormatter is not Sendable, so a shared
        // static would trip Swift 6 concurrency checks.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Rounded to milliseconds so record durations stay readable.
    static func milliseconds(_ interval: TimeInterval) -> Double {
        (interval * 1000).rounded() / 1000
    }

    /// The last ≤2 KB of a captured stderr file, for inline diagnostics.
    func stderrTail(_ path: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        handle.seek(toFileOffset: size > 2048 ? size - 2048 : 0)
        let data = handle.readDataToEndOfFile()
        let text = String(bytes: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else {
            return nil
        }
        return text
    }
}
