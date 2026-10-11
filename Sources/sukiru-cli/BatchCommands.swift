import Foundation
import SukiruCore

struct Batch {
    var decisions: String
    var inputs: ScopeOptions
    var output: OutputOptions
    var mutation: MutationOptions
    var execute = false

    mutating func validate() throws {
        if execute && mutation.dryRun {
            throw CLIUsageError("--dry-run and --execute are mutually exclusive")
        }
        if mutation.yes && !execute { throw CLIUsageError("--yes requires --execute") }
        if mutation.commandTimeout != nil && !execute {
            throw CLIUsageError("--command-timeout requires --execute")
        }
    }

    func run() throws {
        let environment = try cliEnvironment(roots: inputs.roots)
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: decisions)) } catch {
            throw CLIError("Cannot read decisions file \(decisions): \(error.localizedDescription)")
        }
        let entries: [DecisionEntry]
        switch DecisionsFile.parse(data) {
        case .success(let parsed): entries = parsed
        case .failure(let error): throw CLIError(error.message)
        }
        let report = try ScanEngine(environment: environment).scan(inputs.mutationRequest)
        let selectedIDs = Set(
            FindingID.assignments(for: report.findings).filter {
                inputs.findings(in: report).contains($0.finding)
            }.map(\.id))
        guard
            inputs.scope == .all && inputs.host == nil
                || entries.allSatisfy({ selectedIDs.contains($0.findingID) })
        else {
            throw CLIError("Unknown, stale, or out-of-scope finding ID; rescan the selected scope")
        }
        let batch: CommandBatch?
        do {
            batch = try CommandBatchBuilder().build(report: report, decisions: entries)
        } catch let error as BatchBuildError {
            throw CLIError(error.problems.joined(separator: "\n"))
        }
        guard mutation.dryRun || execute else {
            throw CLIError("Review the batch with --dry-run, then execute with --execute --yes")
        }
        try mutation.apply(batch, report: report, environment: environment, output: output)
    }
}

struct Snapshots {
    var output: OutputOptions
    func run() throws {
        let snapshots = SnapshotStore(environment: try cliEnvironment()).list()
        try output.render(
            snapshots, lines: snapshots.map { "\($0.createdAt)  \($0.batchID)  snapshot=\($0.id)" })
    }
}

struct RollbackCommand {
    var batch: String
    var restores: [String] = []
    var preserves: [String] = []
    var output: OutputOptions
    var mutation: MutationOptions

    mutating func validate() throws {
        let paths = restores + preserves
        guard paths.allSatisfy({ $0.hasPrefix("/") }), Set(paths).count == paths.count else {
            throw CLIUsageError("--restore/--preserve require distinct absolute paths")
        }
    }

    func run() throws {
        let rollback = Rollback(environment: try cliEnvironment())
        let preview = try rollback.preview(batchID: batch)
        if mutation.dryRun {
            try output.render(preview, lines: ["Rollback preview: \(preview)"])
            return
        }
        if !output.json { print("Rollback preview: \(preview)") }
        try mutation.confirm(dangerous: false)
        var choices = Dictionary(
            uniqueKeysWithValues: restores.map { ($0, RollbackChoice.restore) })
        for path in preserves { choices[path] = .preserve }
        do {
            let record = try rollback.rollback(batchID: batch, choices: choices)
            try output.render(
                record,
                lines: record.items.map { "\($0.category.rawValue): \($0.path) \($0.reason ?? "")" }
            )
            for item in record.items where item.category == .unrestorableWithReason {
                emitError("unrestorable: \(item.path): \(item.reason ?? "unknown reason")")
            }
        } catch let error as RollbackError {
            if case .conflicts(let review) = error {
                try output.render(
                    review,
                    lines: ["Conflicts require --restore PATH or --preserve PATH: \(review)"])
            }
            throw CLIError(error.message)
        }
    }
}

extension CLI {
    static let batchCommands: [CLICommand] = [
        CLICommand(
            path: "batch", abstract: "Advanced: plan or execute explicit finding decisions.",
            options: [
                CLIOption(
                    "decisions", takesValue: true,
                    help: "JSON decisions file keyed by current finding ID.", required: true)
            ] + scopeOptions + outputOptions + mutationOptions + [
                CLIOption(
                    "execute", takesValue: false,
                    help: "Execute the reviewed decisions rather than only building them.")
            ]
        ) { arguments in
            var command = Batch(
                decisions: try arguments.required("decisions"), inputs: try ScopeOptions(arguments),
                output: OutputOptions(arguments), mutation: try MutationOptions(arguments),
                execute: arguments.flag("execute"))
            try command.validate()
            try command.run()
        },
        CLICommand(
            path: "snapshots", abstract: "List captured Command Batch history.",
            options: outputOptions
        ) { arguments in
            let command = Snapshots(output: OutputOptions(arguments))
            try command.run()
        },
        CLICommand(
            path: "rollback",
            abstract: "Preview or restore a captured batch; resolve conflicts explicitly.",
            options: [
                CLIOption(
                    "batch", takesValue: true, help: "Executed Command Batch ID.", required: true),
                CLIOption(
                    "restore", takesValue: true,
                    help: "Absolute conflict path to restore; repeatable.", repeating: true),
                CLIOption(
                    "preserve", takesValue: true,
                    help: "Absolute conflict path to preserve; repeatable.", repeating: true)
            ] + outputOptions + mutationOptions
        ) { arguments in
            var command = RollbackCommand(
                batch: try arguments.required("batch"), restores: arguments.values("restore"),
                preserves: arguments.values("preserve"), output: OutputOptions(arguments),
                mutation: try MutationOptions(arguments))
            try command.validate()
            try command.run()
        }
    ]
}
