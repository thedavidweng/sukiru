import Foundation

/// Output format for CLI commands. Only JSON is supported in v1.
public enum OutputFormat: String, Equatable, Sendable {
    case json
}

/// A parsed `sukiru-cli` invocation.
public enum CLICommand: Equatable, Sendable {
    case scan(roots: [String], scope: Scope, format: OutputFormat)
    case capabilities(format: OutputFormat)
    case batch(
        decisionsFile: String, dryRun: Bool, execute: Bool, reviewed: Bool,
        commandTimeout: TimeInterval?, roots: [String], scope: Scope,
        format: OutputFormat)
    case rollback(batchID: String, format: OutputFormat)
}

/// A usage error (maps to exit code 1).
public enum CLIParseError: Error, Equatable, Sendable {
    case noCommand
    case unknownCommand(String)
    case unknownFlag(command: String, flag: String)
    case missingValue(flag: String)
    case missingFlag(command: String, flag: String)
    case invalidValue(flag: String, value: String)
    case invalidCombination(command: String, detail: String)

    /// Human-readable message written to stderr.
    public var message: String {
        switch self {
        case .invalidCombination(let command, let detail):
            return "invalid flag combination for '\(command)': \(detail)"
        case .noCommand:
            return "usage: sukiru-cli <scan|capabilities|batch|rollback> [options]"
        case .unknownCommand(let name):
            let usage = "usage: sukiru-cli <scan|capabilities|batch|rollback> [options]"
            return "unknown command '\(name)'. " + usage
        case .unknownFlag(let command, let flag):
            return "unknown flag '\(flag)' for command '\(command)'."
        case .missingValue(let flag):
            return "missing value for '\(flag)'."
        case .missingFlag(let command, let flag):
            return "missing required flag '\(flag)' for command '\(command)'. "
                + "usage: sukiru-cli \(command) \(Self.usageTail(for: command))"
        case .invalidValue(let flag, let value):
            return "invalid value '\(value)' for '\(flag)'."
        }
    }

    /// The command-specific usage fragment shown after a missing flag.
    private static func usageTail(for command: String) -> String {
        switch command {
        case "rollback":
            return "--batch <batch-id>"
        default:
            return "--decisions <file.json> [--dry-run] [--root <path>]…"
        }
    }
}

/// Hand-rolled argument parser for the debug/validation CLI.
///
/// Kept in `SukiruCore` (not the executable target) so it is unit-testable.
public enum CLIParser {
    /// Flags shared by scan and batch.
    private struct SharedOptions {
        var roots: [String] = []
        var scope: Scope = .all
        var format: OutputFormat = .json
    }

    public static func parse(_ arguments: [String]) -> Result<CLICommand, CLIParseError> {
        guard let command = arguments.first else {
            return .failure(.noCommand)
        }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "scan":
            return parseScan(rest)
        case "capabilities":
            return parseCapabilities(rest)
        case "batch":
            return parseBatch(rest)
        case "rollback":
            return parseRollback(rest)
        default:
            return .failure(.unknownCommand(command))
        }
    }

    /// `rollback --batch <batch-id> [--format json]` (D9 one-click
    /// rollback). `--batch` is required and names the executed batch whose
    /// execution record + snapshot drive the restore.
    private static func parseRollback(_ args: [String]) -> Result<CLICommand, CLIParseError> {
        var batchID: String?
        var options = SharedOptions()
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--batch":
                switch requireValue(args, at: index) {
                case .success(let value):
                    batchID = value
                    index += 2
                case .failure(let error):
                    return .failure(error)
                }
            case "--format":
                switch applyShared(arg, args: args, at: index, into: &options) {
                case .success(let next):
                    index = next
                case .failure(let error):
                    return .failure(error)
                }
            default:
                return .failure(.unknownFlag(command: "rollback", flag: arg))
            }
        }
        guard let batchID else {
            return .failure(.missingFlag(command: "rollback", flag: "--batch"))
        }
        return .success(.rollback(batchID: batchID, format: options.format))
    }

    private static func parseScan(_ args: [String]) -> Result<CLICommand, CLIParseError> {
        var options = SharedOptions()
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--root", "--scope", "--format":
                switch applyShared(arg, args: args, at: index, into: &options) {
                case .success(let next):
                    index = next
                case .failure(let error):
                    return .failure(error)
                }
            default:
                return .failure(.unknownFlag(command: "scan", flag: arg))
            }
        }
        return .success(
            .scan(roots: options.roots, scope: options.scope, format: options.format))
    }

    /// Accumulated `batch` flags.
    private struct BatchOptions {
        var decisionsFile: String?
        var dryRun = false
        var execute = false
        var reviewed = false
        var commandTimeout: TimeInterval?
        var shared = SharedOptions()
    }

    /// `batch --decisions <file.json> [--dry-run | --execute [--reviewed]
    /// [--command-timeout <seconds>]] [--root <path>]… [--scope …]
    /// [--format json]` (D12). `--decisions` is required. `--dry-run`
    /// renders the reviewable batch and writes nothing; `--execute` runs the
    /// snapshot/execute pipeline and REFUSES unless `--reviewed`
    /// acknowledges the review (VAL-REPAIR-007).
    private static func parseBatch(_ args: [String]) -> Result<CLICommand, CLIParseError> {
        var options = BatchOptions()
        var index = 0
        while index < args.count {
            switch consumeBatchFlag(args, at: index, into: &options) {
            case .success(let next):
                index = next
            case .failure(let error):
                return .failure(error)
            }
        }
        return finalizeBatch(options)
    }

    /// Consumes one `batch` flag (and its value, when any), returning the
    /// next argument index.
    private static func consumeBatchFlag(
        _ args: [String], at index: Int, into options: inout BatchOptions
    ) -> Result<Int, CLIParseError> {
        let arg = args[index]
        switch arg {
        case "--dry-run":
            options.dryRun = true
            return .success(index + 1)
        case "--execute":
            options.execute = true
            return .success(index + 1)
        case "--reviewed":
            options.reviewed = true
            return .success(index + 1)
        case "--decisions":
            return requireValue(args, at: index).map { value in
                options.decisionsFile = value
                return index + 2
            }
        case "--command-timeout":
            return parseTimeout(args, at: index, into: &options)
        case "--root", "--scope", "--format":
            return applyShared(arg, args: args, at: index, into: &options.shared)
        default:
            return .failure(.unknownFlag(command: "batch", flag: arg))
        }
    }

    /// Parses `--command-timeout <seconds>` (positive seconds only).
    private static func parseTimeout(
        _ args: [String], at index: Int, into options: inout BatchOptions
    ) -> Result<Int, CLIParseError> {
        requireValue(args, at: index).flatMap { value in
            guard let seconds = Double(value), seconds > 0 else {
                return .failure(.invalidValue(flag: args[index], value: value))
            }
            options.commandTimeout = seconds
            return .success(index + 2)
        }
    }

    /// Validates required flags and legal combinations, then builds the
    /// command.
    private static func finalizeBatch(
        _ options: BatchOptions
    ) -> Result<CLICommand, CLIParseError> {
        guard let decisionsFile = options.decisionsFile else {
            return .failure(.missingFlag(command: "batch", flag: "--decisions"))
        }
        if options.dryRun && options.execute {
            return .failure(
                .invalidCombination(
                    command: "batch", detail: "--dry-run and --execute are mutually exclusive"))
        }
        if options.reviewed && !options.execute {
            return .failure(
                .invalidCombination(command: "batch", detail: "--reviewed requires --execute"))
        }
        if options.commandTimeout != nil && !options.execute {
            return .failure(
                .invalidCombination(
                    command: "batch", detail: "--command-timeout requires --execute"))
        }
        return .success(
            .batch(
                decisionsFile: decisionsFile, dryRun: options.dryRun,
                execute: options.execute, reviewed: options.reviewed,
                commandTimeout: options.commandTimeout, roots: options.shared.roots,
                scope: options.shared.scope, format: options.shared.format))
    }

    private static func parseCapabilities(_ args: [String]) -> Result<CLICommand, CLIParseError> {
        var options = SharedOptions()
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--format":
                switch applyShared(arg, args: args, at: index, into: &options) {
                case .success(let next):
                    index = next
                case .failure(let error):
                    return .failure(error)
                }
            default:
                return .failure(.unknownFlag(command: "capabilities", flag: arg))
            }
        }
        return .success(.capabilities(format: options.format))
    }

    /// The value following the flag at `index`, or a missingValue error.
    private static func requireValue(
        _ args: [String], at index: Int
    ) -> Result<String, CLIParseError> {
        guard index + 1 < args.count else {
            return .failure(.missingValue(flag: args[index]))
        }
        return .success(args[index + 1])
    }

    /// Applies one shared flag (`--root`, `--scope`, `--format`) to `options`
    /// and returns the next index.
    private static func applyShared(
        _ flag: String, args: [String], at index: Int, into options: inout SharedOptions
    ) -> Result<Int, CLIParseError> {
        let value: String
        switch requireValue(args, at: index) {
        case .success(let parsed):
            value = parsed
        case .failure(let error):
            return .failure(error)
        }
        switch flag {
        case "--root":
            options.roots.append(value)
        case "--scope":
            guard let parsed = Scope(rawValue: value) else {
                return .failure(.invalidValue(flag: flag, value: value))
            }
            options.scope = parsed
        default:
            guard let parsed = OutputFormat(rawValue: value) else {
                return .failure(.invalidValue(flag: flag, value: value))
            }
            options.format = parsed
        }
        return .success(index + 2)
    }
}
