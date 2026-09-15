/// Output format for CLI commands. Only JSON is supported in v1.
public enum OutputFormat: String, Equatable, Sendable {
    case json
}

/// A parsed `sukiru-cli` invocation.
public enum CLICommand: Equatable, Sendable {
    case scan(roots: [String], scope: Scope, format: OutputFormat)
    case capabilities(format: OutputFormat)
}

/// A usage error (maps to exit code 1).
public enum CLIParseError: Error, Equatable, Sendable {
    case noCommand
    case unknownCommand(String)
    case unknownFlag(command: String, flag: String)
    case missingValue(flag: String)
    case invalidValue(flag: String, value: String)

    /// Human-readable message written to stderr.
    public var message: String {
        switch self {
        case .noCommand:
            return "usage: sukiru-cli <scan|capabilities> [options]"
        case .unknownCommand(let name):
            return "unknown command '\(name)'. usage: sukiru-cli <scan|capabilities> [options]"
        case .unknownFlag(let command, let flag):
            return "unknown flag '\(flag)' for command '\(command)'."
        case .missingValue(let flag):
            return "missing value for '\(flag)'."
        case .invalidValue(let flag, let value):
            return "invalid value '\(value)' for '\(flag)'."
        }
    }
}

/// Hand-rolled argument parser for the debug/validation CLI.
///
/// Kept in `SukiruCore` (not the executable target) so it is unit-testable.
public enum CLIParser {
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
        default:
            return .failure(.unknownCommand(command))
        }
    }

    private static func parseScan(_ args: [String]) -> Result<CLICommand, CLIParseError> {
        var roots: [String] = []
        var scope: Scope = .all
        var format: OutputFormat = .json
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--root":
                guard index + 1 < args.count else {
                    return .failure(.missingValue(flag: "--root"))
                }
                roots.append(args[index + 1])
                index += 2
            case "--scope":
                guard index + 1 < args.count else {
                    return .failure(.missingValue(flag: "--scope"))
                }
                let value = args[index + 1]
                guard let parsed = Scope(rawValue: value) else {
                    return .failure(.invalidValue(flag: "--scope", value: value))
                }
                scope = parsed
                index += 2
            case "--format":
                guard index + 1 < args.count else {
                    return .failure(.missingValue(flag: "--format"))
                }
                let value = args[index + 1]
                guard let parsed = OutputFormat(rawValue: value) else {
                    return .failure(.invalidValue(flag: "--format", value: value))
                }
                format = parsed
                index += 2
            default:
                return .failure(.unknownFlag(command: "scan", flag: arg))
            }
        }
        return .success(.scan(roots: roots, scope: scope, format: format))
    }

    private static func parseCapabilities(_ args: [String]) -> Result<CLICommand, CLIParseError> {
        var format: OutputFormat = .json
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--format":
                guard index + 1 < args.count else {
                    return .failure(.missingValue(flag: "--format"))
                }
                let value = args[index + 1]
                guard let parsed = OutputFormat(rawValue: value) else {
                    return .failure(.invalidValue(flag: "--format", value: value))
                }
                format = parsed
                index += 2
            default:
                return .failure(.unknownFlag(command: "capabilities", flag: arg))
            }
        }
        return .success(.capabilities(format: format))
    }
}
