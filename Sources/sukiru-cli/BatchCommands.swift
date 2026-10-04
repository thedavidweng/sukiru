import ArgumentParser
import Foundation
import SukiruCore

struct Batch: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Advanced: plan or execute explicit finding decisions.")
    @Option(help: "JSON decisions file keyed by current finding ID.") var decisions: String
    @OptionGroup var inputs: ScopeOptions
    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    @Flag(help: "Execute the reviewed decisions rather than only building them.") var execute =
        false

    mutating func validate() throws {
        if execute && mutation.dryRun {
            throw ValidationError("--dry-run and --execute are mutually exclusive")
        }
        if mutation.yes && !execute { throw ValidationError("--yes requires --execute") }
        if mutation.commandTimeout != nil && !execute {
            throw ValidationError("--command-timeout requires --execute")
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

struct Snapshots: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List captured Command Batch history.")
    @OptionGroup var output: OutputOptions
    func run() throws {
        let snapshots = SnapshotStore(environment: try cliEnvironment()).list()
        try output.render(
            snapshots, lines: snapshots.map { "\($0.createdAt)  \($0.batchID)  snapshot=\($0.id)" })
    }
}

struct RollbackCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rollback",
        abstract: "Preview or restore a captured batch; resolve conflicts explicitly.")
    @Option(help: "Executed Command Batch ID.") var batch: String
    @Option(name: .customLong("restore"), help: "Absolute conflict path to restore; repeatable.")
    var restores: [String] = []
    @Option(name: .customLong("preserve"), help: "Absolute conflict path to preserve; repeatable.")
    var preserves: [String] = []
    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions

    mutating func validate() throws {
        let paths = restores + preserves
        guard paths.allSatisfy({ $0.hasPrefix("/") }), Set(paths).count == paths.count else {
            throw ValidationError("--restore/--preserve require distinct absolute paths")
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
