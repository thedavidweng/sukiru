import Foundation
import SukiruCore

struct HookNavigationState {
    var host: PluginHost = .claude
    var selectedID: String?
    var queue: [HookQueuedChange] = []
    var editor: HookEditorTarget?
}

/// The Add Hook / Edit sheet's subject.
enum HookEditorTarget: Identifiable {
    case add(PluginHost)
    case edit(AgentHook)

    var id: String {
        switch self {
        case .add(let host): "add:" + host.rawValue
        case .edit(let hook): "edit:" + hook.id
        }
    }

    var host: PluginHost {
        switch self {
        case .add(let host): host
        case .edit(let hook): hook.source.host
        }
    }
}

struct HookQueuedChange: Identifiable, Equatable {
    let request: HookCleanupRequest
    let hooks: [AgentHook]
    var id: String {
        switch request.action {
        case "add": HookCleanupPlanner.reference(for: request)
        case "edit": "edit:" + (request.hookID ?? "")
        case "set-disable-all": "set-disable-all:" + (request.path ?? "")
        default: request.hookID ?? request.action + ":" + (request.producer ?? "")
        }
    }

    var isCleanup: Bool { !["add", "edit", "set-disable-all"].contains(request.action) }
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
        let hooks = hookState.queue.filter(\.isCleanup).flatMap(\.hooks).filter {
            paths.contains($0.source.path)
        }
        return Dictionary(grouping: hooks, by: \.id).values.compactMap(\.first)
            .sorted { $0.id < $1.id }
    }

    /// Queued additions, edits, and settings changes for a reviewed source, in queue order.
    func reviewedHookChanges(for command: BatchCommand) -> [HookQueuedChange] {
        guard case .replaceHookSource(let path, _, _) = command.fileOperation else { return [] }
        return hookState.queue.filter { !$0.isCleanup && hookChangePath($0) == path }
    }

    /// The source file a queued add, edit, or settings change writes.
    func hookChangePath(_ item: HookQueuedChange) -> String? {
        item.hooks.first?.source.path
            ?? HookCleanupPlanner(environment: Self.makeEnvironment(roots: projectRoots))
            .targetPath(for: item.request)
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

    /// Queues an add, edit, or `disableAllHooks` change after planning it once,
    /// so an invalid change is reported in the sheet rather than at checkout.
    func queueHookChange(_ request: HookCleanupRequest, hooks: [AgentHook] = []) throws {
        guard let inventory = report?.hookInventory else { return }
        _ = try HookCleanupPlanner(environment: Self.makeEnvironment(roots: projectRoots)).plan(
            requests: [request], inventory: inventory)
        let item = HookQueuedChange(request: request, hooks: hooks)
        hookState.queue.removeAll { $0.id == item.id }
        hookState.queue.append(item)
    }

    /// The Claude Code settings file a hook lives in, when it can carry `disableAllHooks`.
    func disableAllHooksPath(for hook: AgentHook) -> String? {
        guard hook.source.host == .claude, hook.source.writable,
            hook.source.path.hasSuffix("/settings.json")
                || hook.source.path.hasSuffix("/settings.local.json")
        else { return nil }
        return hook.source.path
    }

    /// The queued `disableAllHooks` value, else the file's current value.
    func disableAllHooks(atPath path: String) -> Bool {
        hookState.queue.last { $0.request.action == "set-disable-all" && $0.request.path == path }?
            .request.disableAllHooks ?? HookCleanupPlanner.disableAllHooks(atPath: path)
    }

    func setDisableAllHooks(_ flag: Bool, atPath path: String) {
        hookState.queue.removeAll { $0.id == "set-disable-all:" + path }
        guard flag != HookCleanupPlanner.disableAllHooks(atPath: path) else { return }
        try? queueHookChange(
            HookCleanupRequest(action: "set-disable-all", path: path, disableAllHooks: flag))
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
        return try HookCleanupPlanner(environment: Self.makeEnvironment(roots: projectRoots)).plan(
            requests: hookState.queue.map(\.request), inventory: inventory)
    }
}
