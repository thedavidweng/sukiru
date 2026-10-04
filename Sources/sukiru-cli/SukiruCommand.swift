import ArgumentParser
import Darwin
import Foundation
import SukiruCore

@main
struct SukiruCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sukiru", abstract: "Inspect and repair coding-agent libraries.",
        version: productVersion,
        subcommands: [
            Health.self, Clean.self, Fix.self, Skills.self, Plugins.self, Search.self,
            Install.self, Snapshots.self, RollbackCommand.self, Capabilities.self,
            Scan.self, Batch.self, Hooks.self
        ])

    static var productVersion: String {
        var pathSize: UInt32 = 0
        _NSGetExecutablePath(nil, &pathSize)
        var path = [CChar](repeating: 0, count: Int(pathSize))
        _NSGetExecutablePath(&path, &pathSize)
        let executablePath = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let executable = URL(fileURLWithPath: executablePath)
            .resolvingSymlinksInPath()
        let info = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        guard let values = NSDictionary(contentsOf: info),
            let version = values["CFBundleShortVersionString"] as? String
        else { return "development" }
        return version
    }
}

struct Health: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect local Health without launching hosts or refreshing remotely.")
    @OptionGroup var inputs: ScopeOptions
    @OptionGroup var output: OutputOptions
    @Flag(help: "Exit 0 healthy, 1 Problems, 2 scan/environment failure.") var check = false

    func run() throws {
        let environment = try cliEnvironment(roots: inputs.roots)
        let scanned: ScanReport
        do { scanned = try ScanEngine(environment: environment).scan(inputs.request) } catch {
            emitError(error.localizedDescription)
            throw ExitCode(2)
        }
        let report = inputs.selectedReport(scanned)
        let findings = report.findings
        let problems = findings.filter { ProblemKind.of($0).isProblem }
        let pluginProblems = report.pluginInventory?.healthFindings ?? []
        let hookProblems = report.hookInventory?.problems ?? []
        let problemCount = problems.count + pluginProblems.count + hookProblems.count
        let inventoryIssues =
            (report.pluginInventory?.issues.map(\.message) ?? [])
            + (report.hookInventory?.issues.map(\.message) ?? [])
        let status =
            report.issues.isEmpty && inventoryIssues.isEmpty
            ? (problemCount == 0 ? "Healthy" : "\(problemCount) Problem(s)")
            : "Health has scan issues"
        let lines =
            [
                status,
                "\(report.skills.count) Skills in \(report.workspaces.count) workspaces"
            ]
            + findings.map { "\(ProblemKind.of($0).rawValue): \($0.skillName ?? $0.workspaceID)" }
            + pluginProblems.map { "Plugin \($0.kind): \($0.path)" }
            + hookProblems.map { "Hook \($0.health.rawValue): \($0.source.path)" }
            + report.issues.map { "Issue: \($0.message) (\($0.path))" }
            + inventoryIssues.map { "Inventory issue: " + $0 }
        try output.render(report, lines: lines)
        for issue in report.issues { emitError(issue.message) }
        for issue in inventoryIssues { emitError(issue) }
        if check {
            let failedKinds = [
                IssueKind.ledgerUnreadable, IssueKind.directoryUnreadable,
                IssueKind.contentHashUnreadable, IssueKind.skillMDUnreadable
            ]
            let scanFailed =
                report.issues.contains { failedKinds.contains($0.kind) }
                || !inventoryIssues.isEmpty
            if scanFailed {
                throw ExitCode(2)
            }
            if problemCount > 0 || !report.issues.isEmpty { throw ExitCode(1) }
        }
    }
}

struct Clean: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Repair cleanup-class Problems only.")
    @OptionGroup var inputs: ScopeOptions
    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    func run() throws {
        try runRepairs(inputs: inputs, output: output, mutation: mutation, cleanupOnly: true)
    }
}

struct Fix: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Apply deterministic one-click fixes; leave unresolved choices explicit.")
    @OptionGroup var inputs: ScopeOptions
    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    func run() throws {
        try runRepairs(inputs: inputs, output: output, mutation: mutation, cleanupOnly: false)
    }
}

func runRepairs(
    inputs: ScopeOptions, output: OutputOptions, mutation: MutationOptions,
    cleanupOnly: Bool
) throws {
    let environment = try cliEnvironment(roots: inputs.roots)
    let report = try ScanEngine(environment: environment).scan(inputs.mutationRequest)
    let findings = inputs.findings(in: report)
    let assignments = FindingID.assignments(for: report.findings)
    let decisions = assignments.compactMap { entry -> DecisionEntry? in
        guard findings.contains(entry.finding),
            let action = ProblemKind.oneClickFix(for: entry.finding),
            !cleanupOnly || action == .cleanup
        else { return nil }
        return DecisionEntry(findingID: entry.id, action: action)
    }
    let built = CommandBatchBuilder().buildApplicable(report: report, decisions: decisions)
    for skipped in built.skipped { emitError(skipped) }
    for finding in findings
    where ProblemKind.of(finding).isProblem && ProblemKind.oneClickFix(for: finding) == nil {
        emitError(
            "Unresolved \(ProblemKind.of(finding).rawValue): "
                + "\(finding.skillName ?? finding.workspaceID); requires an explicit choice"
        )
    }
    try mutation.apply(built.batch, report: report, environment: environment, output: output)
}

struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Advanced: raw passive scan report.")
    @OptionGroup var inputs: ScopeOptions
    @OptionGroup var output: OutputOptions
    func run() throws {
        let report = try ScanEngine(environment: cliEnvironment(roots: inputs.roots)).scan(
            inputs.request)
        try output.render(
            inputs.selectedReport(report),
            lines: inputs.findings(in: report).map {
                "\($0.ruleID): \($0.skillName ?? $0.workspaceID)"
            })
    }
}

struct Capabilities: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Explicitly probe installed official managers.")
    @OptionGroup var output: OutputOptions
    func run() throws {
        let report = CapabilityDetector(environment: try cliEnvironment()).detect()
        let github =
            report.github.available ? "available" : report.github.reason?.rawValue ?? "unavailable"
        let vercel =
            report.npx.resolvable ? "available" : report.npx.reason?.rawValue ?? "unavailable"
        try output.render(
            report,
            lines: [
                "Vercel (npx skills): \(vercel) \(report.npx.skillsVersion ?? "")",
                "GitHub (gh skill): \(github) \(report.github.version ?? "")"
            ])
    }
}
