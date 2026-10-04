import ArgumentParser
import Darwin
import Foundation
import SukiruCore

extension Scope: ExpressibleByArgument {}
extension InstallerChoice: ExpressibleByArgument {}
extension PlacementMode: ExpressibleByArgument {}
extension SkillSearchResult.Backend: ExpressibleByArgument {}

struct ScopeOptions: ParsableArguments {
    @Option(name: .customLong("root"), help: "Project root; repeat for multiple projects.")
    var roots: [String] = []
    @Option(help: "Inspect user, project, or all scopes.") var scope: Scope = .all
    @Option(help: "Agent Host identifier.") var host: String?

    mutating func validate() throws {
        if let host, !HostTable.hosts.contains(where: { $0.id == host }) {
            throw ValidationError("Unknown Agent Host: \(host)")
        }
        roots = roots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    var request: ScanRequest { ScanRequest(explicitRoots: roots, scope: scope) }
    // A scoped GitHub write can also rewrite the user companion ledger.
    // Preserve all ownership evidence for the core's cross-scope guards.
    var mutationRequest: ScanRequest { ScanRequest(explicitRoots: roots, scope: .all) }

    func skills(in report: ScanReport) -> [Skill] {
        let scoped = report.skills.filter { scope == .all || $0.scope == scope }
        guard host != nil else { return scoped }
        let paths = selectedWorkspaces(in: report).map(\.root)
        return scoped.filter { skill in
            skill.placements.contains { placement in
                paths.contains { placement.path.hasPrefix($0 + "/") }
            }
        }
    }

    func selectedWorkspaces(in report: ScanReport) -> [Workspace] {
        guard let host else { return report.workspaces }
        let environment = SukiruEnvironment(reader: ProcessEnvironmentReader())
        let projectRoots = roots.isEmpty ? environment.projectRoots : roots
        let enumerated = WorkspaceEnumerator(
            environment: environment,
            fileSystem: DefaultFileSystemProbe()
        ).enumerateDetailed(projectRoots: projectRoots)
        let ids = Set(
            enumerated.filter { $0.candidateHosts.contains(host) }.map { $0.workspace.id })
        return report.workspaces.filter { ids.contains($0.id) }
    }

    func findings(in report: ScanReport) -> [Finding] {
        let scoped = report.findings.filter { finding in
            report.workspaces.contains { $0.id == finding.workspaceID && scope.includes($0.kind) }
        }
        guard host != nil else { return scoped }
        let selected = skills(in: report)
        let selectedIDs = Set(selectedWorkspaces(in: report).map(\.id))
        return scoped.filter { finding in
            guard let workspace = report.workspaces.first(where: { $0.id == finding.workspaceID })
            else { return false }
            if finding.skillName == nil {
                return selectedIDs.contains(workspace.id)
            }
            return selected.contains { skill in
                skill.name == finding.skillName
                    && skill.placements.contains { $0.path.hasPrefix(workspace.root + "/") }
            }
        }
    }
    var pluginHost: PluginHost? {
        host.flatMap { resolvedPluginHost(for: $0) }
    }

    func selectedPlugins(_ inventory: PluginInventory) -> PluginInventory {
        guard host != nil else { return inventory }
        let installations = inventory.installations.filter { $0.host == pluginHost }
        let ids = Set(installations.map(\.id))
        return PluginInventory(
            installations: installations,
            marketplaces: inventory.marketplaces.filter { $0.host == pluginHost },
            issues: inventory.issues.filter { $0.host == pluginHost },
            healthFindings: inventory.healthFindings.filter { ids.contains($0.pluginID) })
    }

    func selectedReport(_ report: ScanReport) -> ScanReport {
        guard host != nil else { return report }
        let plugins = report.pluginInventory.map { selectedPlugins($0) }
        let hooks = report.hookInventory.map { inventory in
            HookInventory(
                hooks: inventory.hooks.filter { $0.source.host == pluginHost },
                issues: inventory.issues.filter { $0.host == pluginHost })
        }
        let selectedFindings = findings(in: report)
        let contextIDs = Set(
            selectedWorkspaces(in: report).map(\.id) + selectedFindings.map(\.workspaceID))
        let workspaces = report.workspaces.filter { contextIDs.contains($0.id) }
        return ScanReport(
            workspaces: workspaces, skills: skills(in: report), findings: selectedFindings,
            // Ownership ledgers are shared across Hosts and live outside Skills directories.
            issues: report.issues, lockExtras: report.lockExtras,
            pluginInventory: plugins, hookInventory: hooks)
    }

}

struct OutputOptions: ParsableArguments {
    @Flag(help: "Write structured JSON to stdout; diagnostics go to stderr.") var json = false

    func render<Value: Encodable>(_ value: Value, lines: [String]) throws {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            emitJSON(try encoder.encode(value))
        } else {
            print(lines.joined(separator: "\n"))
        }
    }
}

struct MutationOptions: ParsableArguments {
    @Flag(help: "Render the exact Command Batch without writing anything.") var dryRun = false
    @Flag(name: [.short, .long], help: "Confirm normal execution without prompting.") var yes =
        false
    @Flag(help: "Separately acknowledge dangerous operations and rollback limits.")
    var confirmDangerous = false
    @Option(help: "Per-command timeout in positive seconds.") var commandTimeout: Double?

    mutating func validate() throws {
        if let commandTimeout, !commandTimeout.isFinite || commandTimeout <= 0 {
            throw ValidationError("--command-timeout must be finite and positive")
        }
    }

    func confirm(dangerous: Bool) throws {
        if dangerous && !confirmDangerous {
            throw CLIError(
                "Please review the consequences and supply --confirm-dangerous; --yes does not acknowledge danger"
            )
        }
        if yes { return }
        guard isatty(STDIN_FILENO) != 0 else {
            throw CLIError("Review --dry-run, then supply --yes for non-interactive execution")
        }
        emitError("Execute this Command Batch? [y/N]")
        guard readLine()?.lowercased() == "y" else { throw CLIError("Execution cancelled") }
    }

    func apply(
        _ batch: CommandBatch?, report: ScanReport, environment: SukiruEnvironment,
        output: OutputOptions
    ) throws {
        guard let batch else {
            try output.render(Optional<CommandBatch>.none, lines: ["No applicable changes."])
            return
        }
        if dryRun {
            try output.render(batch, lines: batch.reviewLines)
            return
        }
        if !output.json { print(batch.reviewLines.joined(separator: "\n")) }
        try confirm(dangerous: batch.commands.contains { !$0.dangerFlags.isEmpty })
        let result: ExecutionResult
        do {
            result = try CLIExecutor(
                environment: environment,
                commandTimeout: commandTimeout ?? CLIExecutor.defaultCommandTimeout,
                ghToken: ProcessInfo.processInfo.environment["GH_TOKEN"]
            ).execute(
                batch: batch.transitioned(to: .reviewed), report: report,
                effectsApproved: confirmDangerous)
        } catch let error as ExecutionError {
            throw CLIError(error.message)
        } catch let error as BatchTransitionError {
            throw CLIError(error.message)
        } catch {
            throw CLIError("Execution stopped before the first command: \(error)")
        }
        try output.render(result.record, lines: result.record.summaryLines)
        guard result.record.batchStatus == .succeeded else {
            throw CLIError(
                "Batch failed; inspect command diagnostics. "
                    + "Snapshot \(result.record.snapshotID) is available for rollback."
            )
        }
    }
}

struct CLIError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func cliEnvironment(roots: [String] = []) throws -> SukiruEnvironment {
    var values = ProcessInfo.processInfo.environment
    if !roots.isEmpty { values[SukiruEnvironment.sukiruRootsKey] = roots.joined(separator: ":") }
    let environment = SukiruEnvironment(reader: DictionaryEnvironmentReader(values))
    let problem = environment.fatalProblem(fileSystem: DefaultFileSystemProbe())
    if case .sukiruHomeMissing(let path) = problem {
        emitError("SUKIRU_HOME is set to a path that does not exist: \(path)")
        throw ExitCode(2)
    }
    return environment
}

func emitError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func emitJSON(_ data: Data) {
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func readJSON<Value: Decodable>(_ type: Value.Type, from path: String) throws -> Value {
    try JSONDecoder().decode(type, from: Data(contentsOf: URL(fileURLWithPath: path)))
}

extension CommandBatch {
    var reviewLines: [String] {
        var lines = ["Command Batch \(id): \(commands.count) command(s)"]
        for command in commands {
            lines += [command.displayString, "  " + command.intent]
            if let consequence = command.consequence { lines.append("  " + consequence) }
            if let warning = command.warning { lines.append("  Warning: " + warning) }
            lines += command.dangerFlags.map { "  Danger: " + $0.rawValue }
        }
        return lines
    }

}

extension ExecutionRecord {
    var summaryLines: [String] {
        ["Batch \(batchID): \(batchStatus.rawValue)", "Snapshot: \(snapshotID)"]
            + commands.map { "\($0.status.rawValue): \($0.displayString) \($0.diagnostics ?? "")" }
            + ["Post-execution differences:"] + diff.summary
            + (scanFailure.map { ["Rescan failed: \($0)"] } ?? [])
    }
}
