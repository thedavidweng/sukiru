import Foundation

enum HookExecutionPreflight {
    /// Reconstruct the allowed structural removals, including helper reference checks,
    /// without replacing the reviewed commands or relocating any structural identity.
    static func validate(_ batch: CommandBatch, environment: SukiruEnvironment) throws {
        let mutations = batch.commands.filter { command in
            switch command.fileOperation {
            case .replaceHookSource, .deleteHookHelper: true
            default: false
            }
        }
        guard !mutations.isEmpty else { return }
        let plugins = PluginInventoryReader(environment: environment).read(ScanRequest())
        let inventory = HookInventoryReader(environment: environment).read(
            ScanRequest(), plugins: plugins)
        let ids = Set(batch.findingRefs.filter { $0.ruleID == "hook-cleanup" }.map(\.findingID))
        let requests = inventory.hooks.filter { ids.contains($0.id) }.map {
            HookCleanupRequest(hookID: $0.id)
        }
        let allowed = try HookCleanupPlanner(environment: environment).plan(
            requests: requests, inventory: inventory)
        for mutation in mutations {
            guard let expected = allowed.batch.commands.first(where: { $0.argv == mutation.argv }),
                mutation.captureRoots == expected.captureRoots,
                mutation.hookPreconditions == expected.hookPreconditions,
                mutation.dangerFlags == expected.dangerFlags,
                mutation.owningCLI == .file
            else {
                throw HookError(
                    "Hook cleanup no longer matches the reviewed definitions or helper references. Rescan and replan."
                )
            }
        }
    }
}
