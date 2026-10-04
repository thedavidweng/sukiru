import Foundation
import SukiruCore

struct HookNavigationState {
    var host: PluginHost = .claude
    var selectedID: String?
    var queue: [HookQueuedChange] = []
}

struct HookQueuedChange: Identifiable, Equatable {
    let request: HookCleanupRequest
    let hooks: [AgentHook]
    var id: String { request.hookID ?? request.action + ":" + (request.producer ?? "") }
}

extension AppState {
    var orcaHookDisableAvailable: Bool {
        HookCleanupPlanner(environment: environment).orcaDisableAvailable
    }

    func hookProducerTitle(_ hook: AgentHook) -> String {
        if let plugin = report?.pluginInventory?.installations.first(where: {
            $0.id == hook.source.managingPluginID
        }) {
            return plugin.identifier
        }
        return hook.attribution.producer == "Unknown"
            ? String(localized: "Unknown") : hook.attribution.producer
    }

    func reviewedHooks(for command: BatchCommand) -> [AgentHook] {
        guard command.hookPreconditions != nil else { return [] }
        let paths = Set(command.hookPreconditions?.map(\.path) ?? [])
        let hooks = hookState.queue.flatMap(\.hooks).filter { paths.contains($0.source.path) }
        return Dictionary(grouping: hooks, by: \.id).values.compactMap(\.first)
            .sorted { $0.id < $1.id }
    }

    func hooks(for host: PluginHost) -> [AgentHook] {
        (report?.hookInventory?.hooks ?? []).filter { $0.source.host == host }
    }

    var selectedHook: AgentHook? {
        hooks(for: hookState.host).first { $0.id == hookState.selectedID }
    }

    var hookProblemCount: Int {
        (report?.hookInventory?.problems.count ?? 0) + (report?.hookInventory?.issues.count ?? 0)
    }

    var visibleHookProblems: [AgentHook] {
        guard healthFocus == nil else { return [] }
        return (report?.hookInventory?.problems ?? []).filter { hook in
            let scope =
                hook.source.scopeRoot == environment.home
                ? "user" : "project:" + hook.source.scopeRoot
            return healthWorkspaceFilter == nil || healthWorkspaceFilter == scope
        }
    }

    var visibleHookIssues: [HookInventoryIssue] {
        guard healthFocus == nil else { return [] }
        return (report?.hookInventory?.issues ?? []).filter { issue in
            let scope = issue.scopeRoot == environment.home ? "user" : "project:" + issue.scopeRoot
            return healthWorkspaceFilter == nil || healthWorkspaceFilter == scope
        }
    }

    func inspectHook(_ hook: AgentHook) {
        hookState.host = hook.source.host
        hookState.selectedID = hook.id
        surface = .hooks
    }

    func queueHook(_ hook: AgentHook) {
        let request = HookCleanupRequest(hookID: hook.id)
        hookState.queue.removeAll { $0.id == hook.id }
        hookState.queue.append(HookQueuedChange(request: request, hooks: [hook]))
    }

    func queueHookProducer(_ producer: String, disable: Bool) {
        let request = HookCleanupRequest(
            action: disable ? "disable-producer" : "remove-leftovers", producer: producer)
        let hooks = (report?.hookInventory?.hooks ?? []).filter {
            $0.attribution.producer == producer
                && (disable || ($0.health == .leftover && $0.canRemove))
        }
        let item = HookQueuedChange(request: request, hooks: hooks)
        hookState.queue.removeAll { $0.id == item.id }
        hookState.queue.append(item)
    }

    func hookBatch() throws -> HookCleanupPlan? {
        guard !hookState.queue.isEmpty, let inventory = report?.hookInventory else { return nil }
        for queued in hookState.queue {
            for hook in queued.hooks {
                guard
                    inventory.hooks.contains(where: {
                        $0.id == hook.id && $0.source.contentHash == hook.source.contentHash
                    })
                else {
                    throw HookError(
                        "Hook source changed. Remove the queued cleanup, refresh, and review it again."
                    )
                }
            }
        }
        return try HookCleanupPlanner(environment: environment).plan(
            requests: hookState.queue.map(\.request), inventory: inventory)
    }
}
