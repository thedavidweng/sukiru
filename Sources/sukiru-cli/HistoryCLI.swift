import Foundation
import SukiruCore

struct HistoryCommand {
    enum Action { case prune, clear }

    var action: Action
    var output: OutputOptions
    var yes = false

    func run() throws {
        let retention = HistoryRetention(environment: try cliEnvironment())
        let result: HistoryPruneResult
        do {
            switch action {
            case .prune:
                result = try retention.prune()
            case .clear:
                guard yes else {
                    throw CLIError(
                        "Clearing history removes every snapshot and record, so no batch can be "
                            + "rolled back afterwards; supply --yes to confirm")
                }
                result = try retention.clear()
            }
        } catch let error as ExecutionError {
            throw CLIError(error.message)
        }
        let size = ByteCountFormatter.string(
            fromByteCount: result.reclaimedBytes, countStyle: .file)
        try output.render(
            result,
            lines: [
                "Removed \(result.removedBatches.count) batches (\(size)); "
                    + "\(result.remainingBatches) remain."
            ])
    }
}

extension CLI {
    static let historyCommands: [CLICommand] = [
        CLICommand(
            path: "history",
            abstract: "Apply or clear the snapshot and execution-record retention policy.",
            options: []),
        CLICommand(
            path: "history prune",
            abstract: "Prune history with the limits in settings.json; the newest batch stays.",
            options: outputOptions
        ) { arguments in
            try HistoryCommand(action: .prune, output: OutputOptions(arguments)).run()
        },
        CLICommand(
            path: "history clear",
            abstract:
                "Remove all snapshots and execution records; batches can no longer be rolled back.",
            options: outputOptions + [
                CLIOption(
                    "yes", takesValue: false, help: "Confirm clearing all history.")
            ]
        ) { arguments in
            try HistoryCommand(
                action: .clear, output: OutputOptions(arguments), yes: arguments.flag("yes")
            ).run()
        }
    ]
}
