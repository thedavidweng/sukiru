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
    }
    exit(0)
} catch {
    emitError("sukiru-cli: \(error)")
    exit(1)
}
