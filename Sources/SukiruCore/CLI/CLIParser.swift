/// Output format for CLI commands. Only JSON is supported in v1.
public enum OutputFormat: String, Equatable, Sendable {
    case json
}

/// A parsed `sukiru-cli` invocation.
public enum CLICommand: Equatable, Sendable {
    case scan(roots: [String], scope: Scope, format: OutputFormat)
    case capabilities(format: OutputFormat)
    case batch(
        decisionsFile: String, dryRun: Bool, roots: [String], scope: Scope,
        format: OutputFormat)
}

/// A usage error (maps to exit code 1).
public enum CLIParseError: Error, Equatable, Sendable {
    case noCommand
    case unknownCommand(String)
    case unknownFlag(command: String, flag: String)
    case missingValue(flag: String)
    case missingFlag(command: String, flag: String)
    case invalidValue(flag: String, value: String)

    /// Human-readable message written to stderr.
    public var message: String {
        switch self {
        case .noCommand:
            return "usage: sukiru-cli <scan|capabilities|batch> [options]"
        case .unknownCommand(let name):
            let usage = "usage: sukiru-cli <scan|capabilities|batch> [options]"
            return "unknown command '\(name)'. " + usage
        case .unknownFlag(let command, let flag):
            return "unknown flag '\(flag)' for command '\(command)'."
        case .missingValue(let flag):
            return "missing value for '\(flag)'."
        case .missingFlag(let command, let flag):
            return "missing required flag '\(flag)' for command '\(command)'. "
                + "usage: sukiru-cli batch --decisions <file.json> [--dry-run] [--root <path>]…"
        case .invalidValue(let flag, let value):
            return "invalid value '\(value)' for '\(flag)'."
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
        default:
            return .failure(.unknownCommand(command))
        }
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

    /// `batch --decisions <file.json> [--dry-run] [--root <path>]…
    /// [--scope user|project|all] [--format json]` (D12). `--decisions` is
    /// required; without `--dry-run` the command refuses to execute (the
    /// review/execute pipeline gates execution).
    private static func parseBatch(_ args: [String]) -> Result<CLICommand, CLIParseError> {
        var decisionsFile: String?
        var dryRun = false
        var options = SharedOptions()
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--decisions":
                switch requireValue(args, at: index) {
                case .success(let value):
                    decisionsFile = value
                    index += 2
                case .failure(let error):
                    return .failure(error)
                }
            case "--dry-run":
                dryRun = true
                index += 1
            case "--root", "--scope", "--format":
                switch applyShared(arg, args: args, at: index, into: &options) {
                case .success(let next):
                    index = next
                case .failure(let error):
                    return .failure(error)
                }
            default:
                return .failure(.unknownFlag(command: "batch", flag: arg))
            }
        }
        guard let decisionsFile else {
            return .failure(.missingFlag(command: "batch", flag: "--decisions"))
        }
        return .success(
            .batch(
                decisionsFile: decisionsFile, dryRun: dryRun, roots: options.roots,
                scope: options.scope, format: options.format))
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
