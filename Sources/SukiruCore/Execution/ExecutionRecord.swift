import Foundation

/// Per-command execution outcome (VAL-REPAIR-028 vocabulary): every command
/// in the batch is individually reported, including the ones that never ran.
public enum CommandExecutionStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case succeeded
    case failed
    case timedOut = "timed-out"
    case notRun = "not-run"
}

/// WHY a command failed — the clear terminal states of VAL-REPAIR-039…042.
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
    /// workspace roots and was refused before running (VAL-REPAIR-038).
    case outOfBounds = "out-of-bounds"
}

/// One command's execution record. Nil fields are omitted from the wire
/// JSON: a `not-run` command carries only the identifying fields.
public struct CommandExecution: Codable, Equatable, Sendable {
    public let index: Int
    /// The argv that was exec'd — byte-equal to the reviewed batch's argv
    /// (VAL-REPAIR-058).
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
    /// Absolute paths of the captured output FILES (never pipes —
    /// VAL-REPAIR-029/030).
    public let stdoutFile: String?
    public let stderrFile: String?
    /// ISO-8601 fractional-second timestamps; strictly non-overlapping and
    /// in batch order (VAL-REPAIR-027).
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

/// The batch-level execution record — the seam-B transcript index.
///
/// Persisted as `record.json` inside `recordDirectory`
/// (`<home>/Library/Application Support/Sukiru/executions/<batchID>/`), next
/// to the per-command captured output files `cmd-NN.stdout` /
/// `cmd-NN.stderr`.
public struct ExecutionRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let batchID: String
    /// The snapshot committed BEFORE the first command ran (VAL-REPAIR-023).
    public let snapshotID: String
    /// `succeeded` or `failed` at execution time; a later rollback flips the
    /// persisted record to `rolledBack` (architecture §7).
    public let batchStatus: BatchStatus
    public let commandTimeoutSeconds: Double
    public let startedAt: String
    public let endedAt: String
    public let durationSeconds: Double
    public let recordDirectory: String
    public let commands: [CommandExecution]
    /// The post-run diff (architecture §4.1 Differ): always present, even
    /// when the batch changed nothing (VAL-REPAIR-032/033).
    public let diff: BatchDiff
    /// The batch's affected scope, persisted so a later rollback process
    /// rescans exactly the same surface (the sprayed-symlink gap).
    public let affectedRoots: [String]
    public let affectedScope: Scope
    public let affectedWorkspaceIDs: [String]

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
        affectedWorkspaceIDs: [String]
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
    }

    /// Deterministic JSON encoding (sorted keys), like the batch itself.
    public func jsonData() throws -> Data {
        try deterministicJSONData(self)
    }
}
