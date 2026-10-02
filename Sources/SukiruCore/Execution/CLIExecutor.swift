import Foundation

/// Errors raised BEFORE any command of the batch runs.
public enum ExecutionError: Error, Equatable, Sendable {
    /// The batch was never reviewed — execution is refused with no
    /// snapshot, no subprocess, and no writes.
    case notReviewed(current: BatchStatus)
    /// Another batch execution holds the cross-process lock
    /// (two batches never execute concurrently).
    case busy(lockPath: String)

    /// Human-readable refusal.
    public var message: String {
        switch self {
        case .notReviewed(let current):
            return "refusing to execute: the batch is '\(current.rawValue)', not "
                + "'reviewed' — inspect every command and acknowledge the review first"
        case .busy(let lockPath):
            return "another batch execution is already in progress (execution lock: "
                + "\(lockPath)); wait for it to finish before starting a new batch"
        }
    }
}

/// The outcome of executing a reviewed batch: the batch with its final
/// terminal status and snapshot id, plus the full execution record.
public struct ExecutionResult: Equatable, Sendable {
    public let batch: CommandBatch
    public let record: ExecutionRecord

    public init(batch: CommandBatch, record: ExecutionRecord) {
        self.batch = batch
        self.record = record
    }
}

/// The serialized subprocess runner for Command Batches.
///
/// Invariants enforced here:
/// - **Global serialization**: a process-wide gate plus a cross-process
///   mkdir lock — `npx`/`bunx` share one global install cache and race on
///   cold start.
/// - **Review gate**: only `reviewed` batches execute.
/// - **Snapshot before the first command**, always.
/// - **stdout/stderr to FILES, never pipes** (the 65 536-byte `npx --json`
///   pipe-truncation trap); stdin is `/dev/null` (no TTY).
/// - **Environment contract**: `CI=1`, `SKILLS_TELEMETRY=0`, `HOME` is
///   always the Sukiru-resolved home (= `SUKIRU_HOME` in sandboxes);
///   `GH_TOKEN` is stripped from every child and injected
///   only into gh (github-ledger) commands, never persisted;
///   `npm_config_prefer_offline=true` so `npx skills` runs the CLI already
///   on this Mac instead of silently updating it, and `npm_config_yes=true`
///   so a CLI not yet on this Mac is downloaded instead of prompting on a
///   stdin that cannot answer (see `SkillsCLI`).
/// - **Stop-on-first-failure** with per-command status, exit code, captured
///   output files, and duration.
/// - **Per-command timeout** terminating the child's whole process group.
/// - **Workspace boundary**: direct file operations (the ownerless-cleanup
///   exception) are preflighted against the batch's touched workspace roots
///   and refused out-of-bounds.
public struct CLIExecutor: Sendable {
    /// Default per-command timeout: far above the ~4.7 s cold `npx`
    /// resolution and realistic install times.
    public static let defaultCommandTimeout: TimeInterval = 600

    let environment: SukiruEnvironment
    let commandTimeout: TimeInterval
    /// PATH override for locating and spawning CLIs (validation shim
    /// directories); nil uses the live process PATH.
    let pathOverride: String?
    /// The GitHub token injected into gh commands only. The CLI/app wire in
    /// `ProcessInfo.processInfo.environment["GH_TOKEN"]`; it is never
    /// persisted anywhere by the executor.
    let ghToken: String?

    /// Serializes batch execution process-wide; the cross-process lock in
    /// `execute` extends the same guarantee across app/CLI instances.
    private static let processGate = NSLock()

    public init(
        environment: SukiruEnvironment,
        commandTimeout: TimeInterval = CLIExecutor.defaultCommandTimeout,
        pathOverride: String? = nil,
        ghToken: String? = nil
    ) {
        self.environment = environment
        self.commandTimeout = commandTimeout
        self.pathOverride = pathOverride
        self.ghToken = ghToken
    }

    /// `<home>/Library/Application Support/Sukiru/executions`.
    public func executionsRoot() -> String {
        HostPathResolver.join(
            environment.home, "Library/Application Support/Sukiru/executions")
    }

    /// Executes a reviewed batch: snapshot → serialized commands → record.
    ///
    /// - Throws: `ExecutionError` for pre-command refusals (unreviewed,
    ///   lock held), or `SnapshotError` when the mandatory pre-execution
    ///   snapshot cannot be committed.
    @discardableResult
    public func execute(batch: CommandBatch, report: ScanReport) throws -> ExecutionResult {
        guard batch.status == .reviewed else {
            throw ExecutionError.notReviewed(current: batch.status)
        }
        Self.processGate.lock()
        defer { Self.processGate.unlock() }
        let appSupport = HostPathResolver.join(
            environment.home, "Library/Application Support/Sukiru")
        let lock = ExecutionLock(path: HostPathResolver.join(appSupport, "execution.lock"))
        try lock.acquire()
        defer { lock.release() }

        let recordDirectory = HostPathResolver.join(executionsRoot(), batch.id)
        try FileManager.default.createDirectory(
            atPath: recordDirectory, withIntermediateDirectories: true)

        // Snapshot BEFORE the first command runs — even when the first
        // command fails immediately, the snapshot and its ledger checksums
        // exist; capture is all-or-nothing.
        let store = SnapshotStore(environment: environment)
        let manifest = try store.capture(batch: batch, report: report)

        let batchStart = Date()
        let records = runCommands(
            batch.commands,
            bounds: workspaceBounds(batch: batch, report: report),
            recordDirectory: recordDirectory)

        // Post-run diff: rescan the batch's
        // affected roots and measure against the pre-run scan + snapshot.
        // Computed for succeeded AND failed batches alike — a failed batch's
        // diff documents the partial state.
        let affected = AffectedScope(
            workspaceIDs: batch.findingRefs.map(\.workspaceID))
        let postReport = try ScanEngine(environment: environment).scan(affected.scanRequest)
        let diff = Differ(environment: environment).diff(
            touchedWorkspaceIDs: Set(affected.workspaceIDs),
            pre: report, post: postReport, manifest: manifest)

        let record = try persistRecord(
            batch: batch, snapshotID: manifest.id, started: batchStart,
            outcome: ExecutionOutcome(commands: records, diff: diff, affected: affected),
            recordDirectory: recordDirectory)
        let finalBatch = CommandBatch(
            id: batch.id,
            createdAt: batch.createdAt,
            findingRefs: batch.findingRefs,
            decisions: batch.decisions,
            commands: batch.commands,
            snapshotID: manifest.id,
            status: record.batchStatus)
        return ExecutionResult(batch: finalBatch, record: record)
    }

    /// Runs every command in order, stopping on the first failure;
    /// unreached commands are recorded `.notRun`.
    private func runCommands(
        _ commands: [BatchCommand], bounds: [String], recordDirectory: String
    ) -> [CommandExecution] {
        let violations = preflightFileOperations(commands, bounds: bounds)
        var halted = false
        var records: [CommandExecution] = []
        for (index, command) in commands.enumerated() {
            if halted {
                records.append(Self.notRun(command, index: index))
                continue
            }
            let record: CommandExecution
            if let violation = violations[index] {
                record = Self.preflightFailure(command, index: index, kind: violation)
            } else if command.owningCLI == .file {
                record = runFileOperation(command, index: index, recordDir: recordDirectory)
            } else {
                record = runCLICommand(command, index: index, recordDir: recordDirectory)
            }
            records.append(record)
            if record.status != .succeeded {
                halted = true
            }
        }
        return records
    }

    /// Everything the post-run phase produces, bundled for the record.
    struct ExecutionOutcome {
        let commands: [CommandExecution]
        let diff: BatchDiff
        let affected: AffectedScope
    }

    /// Assembles the batch record and writes `record.json` atomically.
    private func persistRecord(
        batch: CommandBatch, snapshotID: String, started: Date,
        outcome: ExecutionOutcome, recordDirectory: String
    ) throws -> ExecutionRecord {
        let ended = Date()
        let records = outcome.commands
        let status: BatchStatus =
            records.allSatisfy { $0.status == .succeeded } ? .succeeded : .failed
        let record = ExecutionRecord(
            batchID: batch.id,
            snapshotID: snapshotID,
            batchStatus: status,
            commandTimeoutSeconds: commandTimeout,
            startedAt: Self.timestamp(started),
            endedAt: Self.timestamp(ended),
            durationSeconds: Self.milliseconds(ended.timeIntervalSince(started)),
            recordDirectory: recordDirectory,
            commands: records,
            diff: outcome.diff,
            affectedRoots: outcome.affected.roots,
            affectedScope: outcome.affected.scope,
            affectedWorkspaceIDs: outcome.affected.workspaceIDs)
        let recordPath = HostPathResolver.join(recordDirectory, "record.json")
        try record.jsonData().write(to: URL(fileURLWithPath: recordPath), options: .atomic)
        return record
    }

    // MARK: - environment + PATH

    /// The child environment.
    func childEnvironment(for command: BatchCommand) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // GH_TOKEN is stripped from EVERY child and re-injected only into
        // gh (github-ledger) commands; the value is never written to disk.
        environment["GH_TOKEN"] = nil
        environment["CI"] = "1"
        environment["SKILLS_TELEMETRY"] = "0"
        environment["npm_config_prefer_offline"] = "true"
        environment["npm_config_yes"] = "true"
        if !self.environment.home.isEmpty {
            environment["HOME"] = self.environment.home
        }
        if let pathOverride {
            environment["PATH"] = pathOverride
        }
        if command.owningCLI == .github, let ghToken, !ghToken.isEmpty {
            environment["GH_TOKEN"] = ghToken
        }
        if let workingDirectory = command.workingDirectory {
            environment["PWD"] = workingDirectory
        }
        return environment
    }

    /// Resolves an executable name against the effective PATH (absolute
    /// paths pass through). Returns nil when absent or not executable.
    func resolveExecutable(_ name: String) -> URL? {
        let fileManager = FileManager.default
        if name.contains("/") {
            return fileManager.isExecutableFile(atPath: name)
                ? URL(fileURLWithPath: name) : nil
        }
        let searchPath = pathOverride ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in searchPath.split(separator: ":") {
            let candidate = String(directory) + "/" + name
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}
