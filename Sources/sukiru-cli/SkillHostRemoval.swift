import Foundation
import SukiruCore

extension SkillUninstall {
    func removeFromHost() throws {
        let environment = try cliEnvironment(roots: inputs.roots)
        let roots = inputs.roots.isEmpty ? environment.projectRoots : inputs.roots
        let bucket: String
        if inputs.scope == .user {
            bucket = "user"
        } else {
            guard roots.count == 1, let root = roots.first else {
                throw CLIError("Host removal needs exactly one project --root or --scope user.")
            }
            bucket = "project:" + root
        }
        let report = try ScanEngine(environment: environment).scan(inputs.mutationRequest)
        let context = HostRemovalContext(
            environment: environment, report: report, projectRoots: roots)
        let capabilities = CapabilityDetector(environment: environment).detect()
        let builder = CommandBatchBuilder()
        let plan = try builder.planHostRemoval(
            hostID: inputs.host!, bucket: bucket, report: report, context: context,
            capabilities: capabilities)
        let built = builder.buildApplicable(
            report: report, decisions: [], hostRemovals: [plan.request],
            hostRemovalContext: context, capabilities: capabilities)
        if mutation.dryRun {
            try output.render(
                HostRemovalPreview(plan: plan, batch: built.batch),
                lines: plan.reviewLines + (built.batch?.reviewLines ?? []))
            return
        }
        if !output.json { print(plan.reviewLines.joined(separator: "\n")) }
        guard built.skipped.isEmpty else { throw CLIError(built.skipped.joined(separator: "\n")) }
        try mutation.apply(built.batch, report: report, environment: environment, output: output)
    }
}

private struct HostRemovalPreview: Encodable {
    let plan: HostRemovalPlan
    let batch: CommandBatch?
}

extension HostRemovalPlan {
    var reviewLines: [String] {
        var lines = ["Remove Skills from Agent \(hostID) (\(bucket))", "Removed:"]
        lines += removed.map { "  \($0.name): \($0.path)" }
        lines.append("Left in place:")
        lines += leftInPlace.map { "  \($0.entry.name): \($0.entry.path) — \($0.reason.text)" }
        lines.append("Still visible:")
        lines += stillVisible.map { "  \($0.name): \($0.sourceFolder)" }
        if !sharedCopyDeletions.isEmpty {
            lines.append(
                "Also uninstalls from every agent and drops its lock entry: "
                    + sharedCopyDeletions.joined(separator: ", "))
        }
        if predictionUncertain {
            lines.append("Shared Copy deletion prediction is uncertain; review the consequences.")
        }
        if let settingHint { lines.append(settingHint) }
        return lines + problems
    }
}
