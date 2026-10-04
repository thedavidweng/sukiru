import Foundation

/// Per-command execution outcome: every command
/// in the batch is individually reported, including the ones that never ran.
public enum CommandExecutionStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case succeeded
    case failed
    case timedOut = "timed-out"
    case notRun = "not-run"
}

/// WHY a command failed — each kind is a distinct, clearly reported terminal
/// state.
public enum CommandFailureKind: String, Codable, Equatable, Sendable {
    /// The CLI executable was not found on PATH (names the tool in
    /// `diagnostics`).
    case executableMissing = "executable-missing"
    /// The CLI ran and exited non-zero; `diagnostics` carries the stderr
    /// tail, the full capture lives in the output files.
    case nonZeroExit = "non-zero-exit"
    /// The command exceeded the per-command timeout; its process group was
    /// terminated.
    case timeout
    /// posix_spawn itself failed (e.g. missing shebang).
    case spawnFailed = "spawn-failed"
    /// The child was killed by a signal without a timeout.
    case signaled
    /// A direct file operation failed.
    case fileOperationFailed = "file-operation-failed"
    /// A direct file operation targeted a path outside the batch's
    /// workspace roots and was refused before running.
    case outOfBounds = "out-of-bounds"
}

/// One command's execution record. Nil fields are omitted from the wire
/// JSON: a `not-run` command carries only the identifying fields.
public struct CommandExecution: Codable, Equatable, Sendable {
    public let index: Int
    /// The argv that was exec'd — byte-equal to the reviewed batch's argv.
    public let argv: [String]
    public let displayString: String
    public let owningCLI: OwningCLI
    public let intent: String
    public let status: CommandExecutionStatus
    /// The exit code of every completed command (nil for not-run,
    /// executable-missing, and timed-out).
    public let exitCode: Int32?
    public let failureKind: CommandFailureKind?
    /// Human-readable terminal-state diagnostics (missing tool, stderr tail,
    /// timeout note).
    public let diagnostics: String?
    /// Absolute paths of the captured output FILES (never pipes, which
    /// truncate large output).
    public let stdoutFile: String?
    public let stderrFile: String?
    /// ISO-8601 fractional-second timestamps; strictly non-overlapping and
    /// in batch order.
    public let startedAt: String?
    public let endedAt: String?
    public let durationSeconds: Double?

    public init(
        index: Int,
        argv: [String],
        displayString: String,
        owningCLI: OwningCLI,
        intent: String,
        status: CommandExecutionStatus,
        exitCode: Int32?,
        failureKind: CommandFailureKind?,
        diagnostics: String?,
        stdoutFile: String?,
        stderrFile: String?,
        startedAt: String?,
        endedAt: String?,
        durationSeconds: Double?
    ) {
        self.index = index
        self.argv = argv
        self.displayString = displayString
        self.owningCLI = owningCLI
        self.intent = intent
        self.status = status
        self.exitCode = exitCode
        self.failureKind = failureKind
        self.diagnostics = diagnostics
        self.stdoutFile = stdoutFile
        self.stderrFile = stderrFile
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
    }
}

/// The batch-level execution record — the index of a batch's transcript.
///
/// Persisted as `record.json` inside `recordDirectory`
/// (`<home>/Library/Application Support/Sukiru/executions/<batchID>/`), next
/// to the per-command captured output files `cmd-NN.stdout` /
/// `cmd-NN.stderr`.
public struct ExecutionRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let batchID: String
    /// The snapshot committed BEFORE the first command ran.
    public let snapshotID: String
    /// `succeeded` or `failed` at execution time; a later rollback flips the
    /// persisted record to `rolledBack`.
    public let batchStatus: BatchStatus
    public let commandTimeoutSeconds: Double
    public let startedAt: String
    public let endedAt: String
    public let durationSeconds: Double
    public let recordDirectory: String
    public let commands: [CommandExecution]
    /// The post-run diff (computed by `Differ`): always present, even
    /// when the batch changed nothing.
    public let diff: BatchDiff
    /// The batch's affected scope, persisted so a later rollback process
    /// rescans exactly the same surface (the sprayed-symlink gap).
    public let affectedRoots: [String]
    public let affectedScope: Scope
    public let affectedWorkspaceIDs: [String]
    /// Non-nil when post-command file identities could not be committed.
    /// Commands and the pre-execution snapshot remain available in history.
    public let fileEvidenceFailure: String?
    /// Non-nil when the semantic post-command scan did not complete.
    public let scanFailure: String?
    /// Approved runtime/backend effects that captured file restoration cannot undo.
    public let unrestorableEffects: [String]?

    public init(
        schemaVersion: Int = ExecutionRecord.currentSchemaVersion,
        batchID: String,
        snapshotID: String,
        batchStatus: BatchStatus,
        commandTimeoutSeconds: Double,
        startedAt: String,
        endedAt: String,
        durationSeconds: Double,
        recordDirectory: String,
        commands: [CommandExecution],
        diff: BatchDiff,
        affectedRoots: [String],
        affectedScope: Scope,
        affectedWorkspaceIDs: [String],
        fileEvidenceFailure: String? = nil,
        scanFailure: String? = nil,
        unrestorableEffects: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.batchID = batchID
        self.snapshotID = snapshotID
        self.batchStatus = batchStatus
        self.commandTimeoutSeconds = commandTimeoutSeconds
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.recordDirectory = recordDirectory
        self.commands = commands
        self.diff = diff
        self.affectedRoots = affectedRoots
        self.affectedScope = affectedScope
        self.affectedWorkspaceIDs = affectedWorkspaceIDs
        self.fileEvidenceFailure = fileEvidenceFailure
        self.scanFailure = scanFailure
        self.unrestorableEffects = unrestorableEffects
    }

    /// Deterministic JSON encoding (sorted keys), like the batch itself.
    public func jsonData() throws -> Data {
        try deterministicJSONData(self)
    }

    /// Updates only post-command evidence; the command outcome stays intact.
    func recordPostState(
        diff: BatchDiff, fileEvidenceFailure: String? = nil, scanFailure: String? = nil
    ) throws -> ExecutionRecord {
        let observedCommands =
            fileEvidenceFailure == nil && scanFailure == nil
            ? commands.map { $0.observingCursorRefresh(diff: diff) } : commands
        let record = ExecutionRecord(
            schemaVersion: schemaVersion, batchID: batchID, snapshotID: snapshotID,
            batchStatus: fileEvidenceFailure != nil || scanFailure != nil
                || !commands.allSatisfy({ $0.status == .succeeded }) ? .failed : .succeeded,
            commandTimeoutSeconds: commandTimeoutSeconds,
            startedAt: startedAt, endedAt: endedAt, durationSeconds: durationSeconds,
            recordDirectory: recordDirectory, commands: observedCommands, diff: diff,
            affectedRoots: affectedRoots, affectedScope: affectedScope,
            affectedWorkspaceIDs: affectedWorkspaceIDs,
            fileEvidenceFailure: fileEvidenceFailure, scanFailure: scanFailure,
            unrestorableEffects: unrestorableEffects)
        let path = HostPathResolver.join(recordDirectory, "record.json")
        try record.jsonData().write(to: URL(fileURLWithPath: path), options: .atomic)
        return record
    }
}
