import Foundation
import SukiruCore

func runHookCommand(arguments: [String], environment: SukiruEnvironment) -> Bool {
    guard arguments.first == "hooks" else { return false }
    do {
        guard arguments.count >= 2 else { throw HookError("Use hooks inventory|plan|execute") }
        let report = try ScanEngine(environment: environment).scan(ScanRequest())
        if arguments == ["hooks", "inventory"] {
            emitJSON(try report.jsonData())
            return true
        }
        if arguments.count == 4, arguments[1] == "plan", arguments[2] == "--requests" {
            let requests = try JSONDecoder().decode(
                [HookCleanupRequest].self,
                from: Data(contentsOf: URL(fileURLWithPath: arguments[3])))
            let plugins = PluginInventoryReader(environment: environment).read(ScanRequest())
            let inventory = HookInventoryReader(environment: environment).read(
                ScanRequest(), plugins: plugins)
            let plan = try HookCleanupPlanner(environment: environment).plan(
                requests: requests, inventory: inventory)
            emitJSON(try JSONEncoder().encode(plan))
            return true
        }
        guard arguments.count >= 5, arguments[1] == "execute", arguments[2] == "--plan" else {
            throw HookError(
                "Use hooks plan --requests FILE or hooks execute --plan FILE --reviewed --confirm-dangerous"
            )
        }
        let flags = Array(arguments.dropFirst(4))
        guard flags.contains("--reviewed"), flags.contains("--confirm-dangerous"),
            flags.allSatisfy({ ["--reviewed", "--confirm-dangerous"].contains($0) })
        else {
            throw HookError(
                "Review every hook consequence and supply --reviewed --confirm-dangerous")
        }
        let plan = try JSONDecoder().decode(
            HookCleanupPlan.self,
            from: Data(contentsOf: URL(fileURLWithPath: arguments[3])))
        guard plan.instructions.isEmpty, !plan.batch.commands.isEmpty else {
            throw HookError(
                "No executable cleanup; inspect the plan's source/producer instructions")
        }
        let result = try CLIExecutor(environment: environment).execute(
            batch: plan.batch.transitioned(to: .reviewed), report: report, effectsApproved: true)
        emitJSON(try result.record.jsonData())
        if result.record.batchStatus != .succeeded {
            throw HookError("Hook cleanup failed; inspect the execution record and snapshot")
        }
        return true
    } catch {
        emitError(error.localizedDescription)
        exit(1)
    }
}
