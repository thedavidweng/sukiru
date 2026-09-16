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

/// The `batch` command (D12): validate the decisions file, rescan, build the
/// batch, and render it as JSON. Dry-run renders and writes NOTHING
/// (VAL-REPAIR-005); without `--dry-run` the command refuses — execution goes
/// through the review/snapshot pipeline, which gates on an explicit review
/// transition (VAL-REPAIR-007).
func runBatch(
    decisionsFile: String, dryRun: Bool, roots: [String], scope: Scope,
    environment: SukiruEnvironment
) throws {
    guard dryRun else {
        emitError(
            "batch execution requires the review pipeline and is not available "
                + "in this build; re-run with --dry-run to render the batch")
        exit(1)
    }
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: decisionsFile))
    } catch {
        emitError("cannot read decisions file '\(decisionsFile)': \(error.localizedDescription)")
        exit(1)
    }
    let decisions: [DecisionEntry]
    switch DecisionsFile.parse(data) {
    case .failure(let error):
        emitError(error.message)
        exit(1)
    case .success(let parsed):
        decisions = parsed
    }
    let engine = ScanEngine(environment: environment)
    let report = try engine.scan(ScanRequest(explicitRoots: roots, scope: scope))
    do {
        guard let batch = try CommandBatchBuilder().build(report: report, decisions: decisions)
        else {
            emitError("no actionable decisions; no batch created")
            exit(0)
        }
        emitJSON(try batch.jsonData())
    } catch let error as BatchBuildError {
        for problem in error.problems {
            emitError(problem)
        }
        exit(1)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())

let command: CLICommand
switch CLIParser.parse(arguments) {
case .failure(let error):
    emitError(error.message)
    exit(1)
case .success(let parsed):
    command = parsed
}

let environment = SukiruEnvironment(reader: ProcessEnvironmentReader())

// Architecture D4: a set-but-nonexistent SUKIRU_HOME is the sole fatal
// environment problem and maps to exit code 2 for every command.
let fatalProblem = environment.fatalProblem(fileSystem: DefaultFileSystemProbe())
if case .sukiruHomeMissing(let path) = fatalProblem {
    emitError("SUKIRU_HOME is set to a path that does not exist: \(path)")
    exit(2)
}

do {
    switch command {
    case .scan(let roots, let scope, _):
        let engine = ScanEngine(environment: environment)
        let report = try engine.scan(ScanRequest(explicitRoots: roots, scope: scope))
        emitJSON(try report.jsonData())
    case .capabilities:
        // The capabilities command is the ONLY surface allowed to spawn
        // probe subprocesses (architecture D2); scan never does.
        emitJSON(try CapabilityDetector(environment: environment).detect().jsonData())
    case .batch(let decisionsFile, let dryRun, let roots, let scope, _):
        try runBatch(
            decisionsFile: decisionsFile, dryRun: dryRun, roots: roots, scope: scope,
            environment: environment)
    }
    exit(0)
} catch {
    emitError("sukiru-cli: \(error)")
    exit(1)
}
