import Darwin
import Foundation

struct CLIOption: Sendable {
    let name: String
    let takesValue: Bool
    let help: String
    let required: Bool
    let repeating: Bool

    init(
        _ name: String, takesValue: Bool, help: String, required: Bool = false,
        repeating: Bool = false
    ) {
        self.name = name
        self.takesValue = takesValue
        self.help = help
        self.required = required
        self.repeating = repeating
    }
}

struct CLIPositional: Sendable {
    let name: String
    let required: Bool
    let help: String
}

struct CLICommand: Sendable {
    let path: String
    let abstract: String
    let options: [CLIOption]
    let argument: CLIPositional?
    let run: (@Sendable (CLIArguments) async throws -> Void)?

    init(
        path: String, abstract: String, options: [CLIOption], argument: CLIPositional? = nil,
        run: (@Sendable (CLIArguments) async throws -> Void)? = nil
    ) {
        self.path = path
        self.abstract = abstract
        self.options = options
        self.argument = argument
        self.run = run
    }

    var usage: String {
        var parts = ["sukiru", path].filter { !$0.isEmpty }
        if let argument {
            parts.append(argument.required ? "<\(argument.name)>" : "[<\(argument.name)>]")
        }
        parts += options.map { option in
            let token = option.takesValue ? "--\(option.name) <\(option.name)>" : "--\(option.name)"
            return option.required ? token : "[\(token)\(option.repeating ? " ..." : "")]"
        }
        if run == nil { parts.append("<subcommand>") }
        return parts.joined(separator: " ")
    }
}

enum CLI {
    static let commands =
        rootCommands + skillCommands + pluginCommands + hookCommands
        + batchCommands + discoveryCommands
    static let builtIns = [
        CLIOption("help", takesValue: false, help: "Show help information."),
        CLIOption("version", takesValue: false, help: "Show the version.")
    ]

    static func main() async {
        let tokens = Array(CommandLine.arguments.dropFirst())
        let helpCommand = tokens.first == "help"
        let commandTokens = helpCommand ? Array(tokens.dropFirst()) : tokens
        let command = selectedCommand(commandTokens)
        let remaining = commandTokens.dropFirst(command.path.split(separator: " ").count)
        do {
            if let script = try completionScript(tokens) {
                print(script)
                return
            }
            let arguments = try CLIArguments(Array(remaining), options: command.options + builtIns)
            if arguments.flag("help") {
                printHelp(command)
                return
            }
            if arguments.flag("version") {
                print(SukiruCommand.productVersion)
                return
            }
            if helpCommand {
                printHelp(command)
                return
            }
            try validate(arguments, command: command)
            guard let run = command.run else {
                printHelp(command)
                return
            }
            try await run(arguments)
        } catch let error as CLIExit {
            exit(error.code)
        } catch let error as CLIUsageError {
            emitError("Error: " + error.message)
            emitError("Usage: " + command.usage)
            emitError(
                "  See '\(command.path.isEmpty ? "sukiru" : "sukiru " + command.path) --help' for more information."
            )
            exit(64)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            emitError("Error: " + message)
            exit(1)
        }
    }

    private static func selectedCommand(_ tokens: [String]) -> CLICommand {
        commands.filter { command in
            Array(tokens.prefix(command.path.split(separator: " ").count))
                == command.path.split(separator: " ").map(String.init)
        }.max { $0.path.count < $1.path.count }!
    }

    private static func validate(_ arguments: CLIArguments, command: CLICommand) throws {
        if let error = arguments.errors.first { throw CLIUsageError(error) }
        if arguments.positionals.count > (command.argument == nil ? 0 : 1) {
            let unexpected = arguments.positionals[command.argument == nil ? 0 : 1]
            throw CLIUsageError("Unexpected argument '\(unexpected)'")
        }
        if let argument = command.argument, argument.required, arguments.positional == nil {
            throw CLIUsageError("Missing expected argument '<\(argument.name)>'")
        }
    }

    private static func printHelp(_ command: CLICommand) {
        print("OVERVIEW: \(command.abstract)\n\nUSAGE: \(command.usage)")
        if let argument = command.argument {
            print("\nARGUMENTS:\n  <\(argument.name)>  \(argument.help)")
        }
        print("\nOPTIONS:")
        for option in command.options + builtIns {
            let name =
                option.name == "help"
                ? "-h, --help"
                : option.name == "yes" ? "-y, --yes" : "--" + option.name
            print("  \(name)\(option.takesValue ? " <\(option.name)>" : "")  \(option.help)")
        }
        let prefix = command.path.isEmpty ? "" : command.path + " "
        let children = commands.filter {
            $0.path.hasPrefix(prefix) && $0.path != command.path
                && !$0.path.dropFirst(prefix.count).contains(" ")
        }
        if !children.isEmpty {
            print("\nSUBCOMMANDS:")
            for child in children {
                print("  \(child.path.dropFirst(prefix.count))  \(child.abstract)")
            }
            if command.path.isEmpty { print("  help  Show subcommand help information.") }
        }
    }
}
