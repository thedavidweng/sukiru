import Foundation
import SukiruCore

func runPluginCommand(arguments: [String], environment: SukiruEnvironment) -> Bool {
    guard arguments.first == "plugins" else { return false }
    do {
        guard arguments.count >= 2 else {
            throw PluginLifecycleError(
                message:
                    "Use plugins plan|execute --requests FILE or plugins capabilities --host HOST")
        }
        if arguments[1] == "capabilities" {
            guard arguments.count == 4, arguments[2] == "--host",
                let host = PluginHost(rawValue: arguments[3])
            else {
                throw PluginLifecycleError(
                    message: "Use plugins capabilities --host claude|codex|opencode")
            }
            let capabilities = try PluginLifecyclePlanner(environment: environment).capabilities(
                host: host)
            emitJSON(try JSONEncoder().encode(capabilities))
            return true
        }
        try runPluginLifecycle(arguments: arguments, environment: environment)
        return true
    } catch {
        emitError(error.localizedDescription)
        exit(1)
    }
}

private func runPluginLifecycle(arguments: [String], environment: SukiruEnvironment) throws {
    guard ["plan", "execute"].contains(arguments[1]), arguments.count >= 4,
        arguments[2] == "--requests"
    else {
        throw PluginLifecycleError(message: "Use plugins plan|execute --requests FILE")
    }
    let flags = Array(arguments.dropFirst(4))
    guard flags.allSatisfy({ ["--reviewed", "--confirm-dangerous"].contains($0) }) else {
        throw PluginLifecycleError(message: "Unknown plugin command flag")
    }
    let requests = try JSONDecoder().decode(
        [PluginLifecycleRequest].self,
        from: Data(contentsOf: URL(fileURLWithPath: arguments[3])))
    let report = try ScanEngine(environment: environment).scan(
        ScanRequest(explicitRoots: environment.projectRoots, scope: .all))
    let inventory = PluginInventoryReader(environment: environment).read(
        ScanRequest(explicitRoots: environment.projectRoots, scope: .all))
    let plan = try PluginLifecyclePlanner(environment: environment).plan(
        requests: requests, inventory: inventory)
    if arguments[1] == "plan" {
        emitJSON(try JSONEncoder().encode(plan))
        return
    }
    try executePluginPlan(plan, flags: flags, report: report, environment: environment)
}

private func executePluginPlan(
    _ plan: PluginLifecyclePlan, flags: [String], report: ScanReport,
    environment: SukiruEnvironment
) throws {
    guard plan.instructions.isEmpty, let batch = plan.batch else {
        emitJSON(try JSONEncoder().encode(plan))
        throw PluginLifecycleError(
            message: "Operation incomplete; follow the host instructions and refresh afterwards"
        )
    }
    guard flags.contains("--reviewed") else {
        throw PluginLifecycleError(message: "Review plugins plan, then supply --reviewed")
    }
    let dangerous = batch.commands.contains { !$0.dangerFlags.isEmpty }
    if dangerous && !flags.contains("--confirm-dangerous") {
        throw PluginLifecycleError(
            message: "Review operation effects and rollback limits, then supply --confirm-dangerous"
        )
    }
    let result = try CLIExecutor(environment: environment).execute(
        batch: batch.transitioned(to: .reviewed), report: report,
        effectsApproved: flags.contains("--confirm-dangerous"))
    emitJSON(try result.record.jsonData())
    guard result.record.batchStatus == .succeeded else {
        throw PluginLifecycleError(
            message:
                "Operation incomplete; inspect the captured command diagnostics. "
                + "If approval was refused, re-run in the host approval workflow, then refresh. "
                + "No pending request or automatic resumption is assumed. Snapshot rollback is available."
        )
    }
}
