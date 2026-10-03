import Foundation
import SukiruCore

/// Writes a line to stderr.
func emitError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Writes JSON to stdout with a trailing newline.
func emitJSON(_ data: Data) {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

/// Everything the `batch` command needs, bundled to keep `runBatch` small.
struct BatchInvocation {
    let decisionsFile: String
    let dryRun: Bool
    let execute: Bool
    let reviewed: Bool
    let commandTimeout: TimeInterval?
    let roots: [String]
    let scope: Scope
    let environment: SukiruEnvironment
}

/// The `batch` command: validate the decisions file, rescan, build the
/// batch, then render it (`--dry-run`, writes NOTHING) or
/// execute it through the snapshot/serialize/execute pipeline (`--execute`).
/// Execution gates on the explicit `--reviewed` acknowledgement;
/// it prints the execution record JSON and exits 0 only
/// when the batch succeeded.
func runBatch(_ invocation: BatchInvocation) throws {
    let decisions = loadDecisions(from: invocation.decisionsFile)
    let engine = ScanEngine(environment: invocation.environment)
    let report = try engine.scan(
        ScanRequest(explicitRoots: invocation.roots, scope: invocation.scope))
    guard let batch = buildBatch(report: report, decisions: decisions) else {
        emitError("no actionable decisions; no batch created")
        exit(0)
    }
    if invocation.dryRun {
        emitJSON(try batch.jsonData())
        return
    }
    guard invocation.execute else {
        emitError(
            "batch built but not executed: re-run with --dry-run to review it, "
                + "or with --execute --reviewed to execute it")
        exit(1)
    }
    guard invocation.reviewed else {
        emitError(
            "refusing to execute batch '\(batch.id)': it has not been reviewed; "
                + "inspect every command with --dry-run, then re-run adding --reviewed")
        exit(1)
    }
    executeBatch(batch, report: report, invocation: invocation)
}

/// Reads and parses the decisions file; exits 1 with a clear message on
/// unreadable or invalid input.
func loadDecisions(from decisionsFile: String) -> [DecisionEntry] {
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: decisionsFile))
    } catch {
        emitError("cannot read decisions file '\(decisionsFile)': \(error.localizedDescription)")
        exit(1)
    }
    switch DecisionsFile.parse(data) {
    case .failure(let error):
        emitError(error.message)
        exit(1)
    case .success(let parsed):
        return parsed
    }
}

/// Builds the batch; exits 1 listing every problem on failure. Nil means no
/// actionable decisions.
func buildBatch(report: ScanReport, decisions: [DecisionEntry]) -> CommandBatch? {
    do {
        return try CommandBatchBuilder().build(report: report, decisions: decisions)
    } catch let error as BatchBuildError {
        for problem in error.problems {
            emitError(problem)
        }
        exit(1)
    } catch {
        emitError("cannot build the batch: \(error)")
        exit(1)
    }
}

/// Runs the reviewed batch through the executor, prints the execution
/// record JSON, and exits 1 with per-command diagnostics on failure.
func executeBatch(
    _ batch: CommandBatch, report: ScanReport, invocation: BatchInvocation
) {
    let executor = CLIExecutor(
        environment: invocation.environment,
        commandTimeout: invocation.commandTimeout ?? CLIExecutor.defaultCommandTimeout,
        ghToken: ProcessInfo.processInfo.environment["GH_TOKEN"])
    let result: ExecutionResult
    do {
        result = try executor.execute(
            batch: batch.transitioned(to: .reviewed), report: report)
    } catch let error as ExecutionError {
        emitError(error.message)
        exit(1)
    } catch let error as BatchTransitionError {
        emitError(error.message)
        exit(1)
    } catch {
        emitError("execution failed before the first command ran: \(error)")
        exit(1)
    }
    do {
        emitJSON(try result.record.jsonData())
    } catch {
        emitError("cannot render the execution record: \(error)")
        exit(1)
    }
    if result.record.batchStatus == .succeeded {
        return
    }
    let failed = result.record.commands.filter { $0.status != .succeeded }
    for command in failed {
        let detail = command.diagnostics ?? command.status.rawValue
        emitError("command \(command.index) \(command.status.rawValue): \(detail)")
    }
    let rollback =
        "batch '\(batch.id)' failed; snapshot '\(result.record.snapshotID)' "
        + "is available for rollback"
    emitError(rollback)
    exit(1)
}

/// The `rollback` command: restores the batch's pre-execution state
/// and prints the itemized rollback record JSON. Exit 0 even when some
/// items are unrestorable — the record reports them honestly and stderr
/// surfaces each one; exit 1 is reserved for refusals (unknown batch,
/// already rolled back, execution in progress, unreadable snapshot).
func runRollback(
    batchID: String, environment: SukiruEnvironment, preview: Bool,
    choices: [String: RollbackChoice]
) {
    let record: RollbackRecord
    do {
        let rollback = Rollback(environment: environment)
        if preview {
            emitJSON(try rollback.preview(batchID: batchID).jsonData())
            return
        }
        record = try rollback.rollback(batchID: batchID, choices: choices)
    } catch let error as RollbackError {
        if case .conflicts(let review) = error, let bytes = try? review.jsonData() {
            emitJSON(bytes)
        }
        emitError(error.message)
        exit(1)
    } catch let error as ExecutionError {
        emitError(error.message)
        exit(1)
    } catch {
        emitError("rollback of batch '\(batchID)' failed: \(error)")
        exit(1)
    }
    do {
        emitJSON(try record.jsonData())
    } catch {
        emitError("cannot render the rollback record: \(error)")
        exit(1)
    }
    for item in record.items where item.category == .unrestorableWithReason {
        emitError("unrestorable: \(item.path): \(item.reason ?? "unknown reason")")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())

let environment = SukiruEnvironment(reader: ProcessEnvironmentReader())

// A set-but-nonexistent SUKIRU_HOME is the sole fatal
// environment problem and maps to exit code 2 for every command.
let fatalProblem = environment.fatalProblem(fileSystem: DefaultFileSystemProbe())
if case .sukiruHomeMissing(let path) = fatalProblem {
    emitError("SUKIRU_HOME is set to a path that does not exist: \(path)")
    exit(2)
}

if runPluginCommand(arguments: arguments, environment: environment) { exit(0) }

let command: CLICommand
switch CLIParser.parse(arguments) {
case .failure(let error):
    emitError(error.message)
    exit(1)
case .success(let parsed):
    command = parsed
}

do {
    switch command {
    case .scan(let roots, let scope, _):
        let engine = ScanEngine(environment: environment)
        let report = try engine.scan(ScanRequest(explicitRoots: roots, scope: scope))
        emitJSON(try report.jsonData())
    case .capabilities:
        // The capabilities command is the ONLY surface allowed to spawn
        // probe subprocesses; scan never does.
        emitJSON(try CapabilityDetector(environment: environment).detect().jsonData())
    case .batch(
        let decisionsFile, let dryRun, let execute, let reviewed,
        let commandTimeout, let roots, let scope, _):
        try runBatch(
            BatchInvocation(
                decisionsFile: decisionsFile, dryRun: dryRun, execute: execute,
                reviewed: reviewed, commandTimeout: commandTimeout, roots: roots,
                scope: scope, environment: environment))
    case .rollback(let batchID, _, let preview, let choices):
        runRollback(batchID: batchID, environment: environment, preview: preview, choices: choices)
    }
    exit(0)
} catch {
    emitError("sukiru-cli: \(error)")
    exit(1)
}
