import Foundation
import SukiruCore

struct HookNavigationState {
    var host: HookHost = .claude
    var selectedID: String?
    var extensionHost: ExtensionHost = .pi
    /// The MCP Servers destination of `extensionHost` rather than its other add-ons.
    var showsMCP = false
    var selectedExtensionID: String?
    var queue: [HookQueuedChange] = []
    var editor: HookEditorTarget?
}

/// The Add Hook / Edit sheet's subject.
enum HookEditorTarget: Identifiable {
    case add(HookHost)
    case edit(AgentHook)

    var id: String {
        switch self {
        case .add(let host): "add:" + host.rawValue
        case .edit(let hook): "edit:" + hook.id
        }
    }

    var host: HookHost {
        switch self {
        case .add(let host): host
        case .edit(let hook): hook.source.host
        }
    }
}

struct ProducerLeftover {
    let producer: String
    let hooks: Int
    let extensions: Int
}

struct HookQueuedChange: Identifiable, Equatable {
    let request: HookCleanupRequest
    let hooks: [AgentHook]
    var extensions: [AgentExtension] = []
    var id: String {
        switch request.action {
        case "remove-extension", "disable-extension", "enable-extension":
            "extension:" + (request.extensionID ?? "")
        case "add": HookCleanupPlanner.reference(for: request)
        case "edit": "edit:" + (request.hookID ?? "")
        case "set-disable-all": "set-disable-all:" + (request.path ?? "")
        case "set-hook-enabled": "enabled:" + (request.hookID ?? "")
        default: request.hookID ?? request.action + ":" + (request.producer ?? "")
        }
    }

    var isCleanup: Bool {
        !["add", "edit", "set-disable-all", "set-hook-enabled"].contains(request.action)
    }
}

extension AppState {
    var orcaHookDisableAvailable: Bool {
        HookCleanupPlanner(environment: environment).orcaDisableAvailable
    }

    func extensions(for host: ExtensionHost, mcp: Bool) -> [AgentExtension] {
        (report?.extensionInventory?.extensions ?? []).filter {
            $0.host == host && ($0.category == .mcpServer) == mcp
        }
    }

    var selectedExtension: AgentExtension? {
        extensions(for: hookState.extensionHost, mcp: hookState.showsMCP).first {
            $0.id == hookState.selectedExtensionID
        }
    }

    func queuedExtensionAction(_ item: AgentExtension) -> ExtensionAction? {
        hookState.queue.first { $0.id == "extension:" + item.id }
            .flatMap { ExtensionAction(rawValue: String($0.request.action.prefix { $0 != "-" })) }
    }

    func queueExtension(_ item: AgentExtension, action: ExtensionAction = .remove) {
        let change = HookQueuedChange(
            request: HookCleanupRequest(
                action: action.rawValue + "-extension", extensionID: item.id),
            hooks: [], extensions: [item])
        hookState.queue.removeAll { $0.id == change.id }
        hookState.queue.append(change)
    }

    /// Absent producers that left hooks or extensions behind, for one-step cleanup.
    var producerLeftovers: [ProducerLeftover] {
        let planner = HookCleanupPlanner(environment: environment)
        return ["Orca", "Muxy"].compactMap { producer in
            guard !planner.producerInstalled(producer) else { return nil }
            let hooks = (report?.hookInventory?.hooks ?? []).filter {
                $0.attribution.producer == producer && $0.health == .leftover && $0.canRemove
            }.count
            let extensions = (report?.extensionInventory?.extensions ?? []).filter {
                $0.producer == producer
            }.count
            return hooks + extensions == 0
                ? nil : ProducerLeftover(producer: producer, hooks: hooks, extensions: extensions)
        }
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

    func hooks(for host: HookHost) -> [AgentHook] {
        (report?.hookInventory?.hooks ?? []).filter { $0.source.host == host }
    }

    var selectedHook: AgentHook? {
        hooks(for: hookState.host).first { $0.id == hookState.selectedID }
    }

    /// Leftover hooks are already problems; a producer that left only extensions adds one.
    var hookProblemCount: Int {
        (report?.hookInventory?.problems.count ?? 0) + (report?.hookInventory?.issues.count ?? 0)
            + producerLeftovers.filter { $0.hooks == 0 }.count
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
        let extensions =
            disable
            ? [] : (report?.extensionInventory?.extensions ?? []).filter { $0.producer == producer }
        let item = HookQueuedChange(request: request, hooks: hooks, extensions: extensions)
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

    /// The hook's file, when its host documents a file-wide `disableAllHooks` switch.
    func disableAllHooksPath(for hook: AgentHook) -> String? {
        let planner = HookCleanupPlanner(environment: Self.makeEnvironment(roots: projectRoots))
        guard hook.source.writable, planner.disableAllHost(forPath: hook.source.path) != nil
        else { return nil }
        return hook.source.path
    }

    /// The queued per-hook switch, else the hook's current value.
    func hookEnabled(_ hook: AgentHook) -> Bool {
        hookState.queue.last {
            $0.request.action == "set-hook-enabled" && $0.request.hookID == hook.id
        }?
        .request.enabled ?? HookCleanupPlanner.hookEnabled(hook)
    }

    func setHookEnabled(_ flag: Bool, hook: AgentHook) {
        hookState.queue.removeAll {
            $0.request.action == "set-hook-enabled" && $0.request.hookID == hook.id
        }
        guard flag != HookCleanupPlanner.hookEnabled(hook) else { return }
        try? queueHookChange(
            HookCleanupRequest(action: "set-hook-enabled", hookID: hook.id, enabled: flag),
            hooks: [hook])
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
        guard !hookState.queue.isEmpty else { return nil }
        let inventory = report?.hookInventory ?? HookInventory(hooks: [], issues: [])
        let extensions = report?.extensionInventory ?? ExtensionInventory(extensions: [])
        for queued in hookState.queue {
            for item in queued.extensions where !extensions.extensions.contains(item) {
                throw HookError(
                    "Extension changed. Remove the queued cleanup, refresh, and review it again.")
            }
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
            requests: hookState.queue.map(\.request), inventory: inventory, extensions: extensions)
    }
}
