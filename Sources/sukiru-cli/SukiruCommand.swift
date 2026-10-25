import Darwin
import Foundation
import SukiruCore

@main
struct SukiruCommand {
    static func main() async { await CLI.main() }

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

struct Health {
    var inputs: ScopeOptions
    var output: OutputOptions
    var check = false

    func run() throws {
        let environment = try cliEnvironment(roots: inputs.roots)
        let scanned: ScanReport
        do { scanned = try ScanEngine(environment: environment).scan(inputs.request) } catch {
            emitError(error.localizedDescription)
            throw CLIExit(2)
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
            + (report.pnpmObservations ?? []).map {
                "pnpm \($0.permission.rawValue): \($0.selector) (\($0.projectRoot)); "
                    + ($0.installed ? "verified links installed" : "no verified links")
                    + "; manage permissions and dependencies with pnpm"
            }
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
                throw CLIExit(2)
            }
            if problemCount > 0 || !report.issues.isEmpty { throw CLIExit(1) }
        }
    }
}

struct Clean {
    var inputs: ScopeOptions
    var output: OutputOptions
    var mutation: MutationOptions
    func run() throws {
        try runRepairs(inputs: inputs, output: output, mutation: mutation, cleanupOnly: true)
    }
}

struct Fix {
    var inputs: ScopeOptions
    var output: OutputOptions
    var mutation: MutationOptions
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
    // Probed only when a fix would need `npx skills`, matching the app's Fix All.
    var capabilities: CapabilityReport?
    let decisions = assignments.compactMap { entry -> DecisionEntry? in
        guard findings.contains(entry.finding),
            let candidate = ProblemKind.oneClickFix(for: entry.finding),
            !cleanupOnly || candidate == .cleanup
        else { return nil }
        if ProblemKind.oneClickFix(for: entry.finding, capabilities: .pending()) == nil {
            if capabilities == nil {
                capabilities = CapabilityDetector(environment: environment).detect()
            }
            guard ProblemKind.oneClickFix(for: entry.finding, capabilities: capabilities) != nil
            else {
                emitError(
                    "Skipped \(ProblemKind.of(entry.finding).rawValue): "
                        + "\(entry.finding.skillName ?? entry.finding.workspaceID); "
                        + "the fix needs npx skills, which is not available")
                return nil
            }
        }
        return DecisionEntry(findingID: entry.id, action: candidate)
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

struct Scan {
    var inputs: ScopeOptions
    var output: OutputOptions
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

struct Capabilities {
    var output: OutputOptions
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

extension CLI {
    static let rootCommands: [CLICommand] = [
        CLICommand(path: "", abstract: "Inspect and repair coding-agent libraries.", options: []),
        CLICommand(
            path: "health",
            abstract: "Inspect local Health without launching hosts or refreshing remotely.",
            options: scopeOptions + outputOptions + [
                CLIOption(
                    "check", takesValue: false,
                    help: "Exit 0 healthy, 1 Problems, 2 scan/environment failure.")
            ]
        ) { arguments in
            let command = Health(
                inputs: try ScopeOptions(arguments), output: OutputOptions(arguments),
                check: arguments.flag("check"))
            try command.run()
        },
        CLICommand(
            path: "clean", abstract: "Repair cleanup-class Problems only.",
            options: scopeOptions + outputOptions + mutationOptions
        ) { arguments in
            let command = Clean(
                inputs: try ScopeOptions(arguments), output: OutputOptions(arguments),
                mutation: try MutationOptions(arguments))
            try command.run()
        },
        CLICommand(
            path: "fix",
            abstract: "Apply deterministic one-click fixes; leave unresolved choices explicit.",
            options: scopeOptions + outputOptions + mutationOptions
        ) { arguments in
            let command = Fix(
                inputs: try ScopeOptions(arguments), output: OutputOptions(arguments),
                mutation: try MutationOptions(arguments))
            try command.run()
        },
        CLICommand(
            path: "scan", abstract: "Advanced: raw passive scan report.",
            options: scopeOptions + outputOptions
        ) { arguments in
            let command = Scan(
                inputs: try ScopeOptions(arguments), output: OutputOptions(arguments))
            try command.run()
        },
        CLICommand(
            path: "capabilities", abstract: "Explicitly probe installed official managers.",
            options: outputOptions
        ) { arguments in
            let command = Capabilities(output: OutputOptions(arguments))
            try command.run()
        }
    ]
}
