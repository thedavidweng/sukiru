import Foundation

/// The command handler an `add` or `edit` request writes. Other handler types stay read-only.
public struct HookHandlerSpec: Codable, Equatable, Sendable {
    public let type: String
    public let command: String
    public let timeout: Int?
    /// Codex only; Claude Code handlers keep any existing value untouched.
    public let statusMessage: String?

    public init(command: String, timeout: Int? = nil, statusMessage: String? = nil) {
        self.type = "command"
        self.command = command
        self.timeout = timeout
        self.statusMessage = statusMessage
    }
}

/// Hook events each host documents for standalone configuration.
public enum HookEvents {
    /// https://code.claude.com/docs/en/hooks
    public static let claude = [
        "PreToolUse", "PostToolUse", "PostToolUseFailure", "Notification", "UserPromptSubmit",
        "Stop", "SubagentStart", "SubagentStop", "PreCompact", "SessionStart", "SessionEnd",
        "PermissionRequest"
    ]
    /// https://learn.chatgpt.com/docs/hooks — other identifiers are accepted with a warning.
    public static let codex = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
        "Stop", "SubagentStart", "SubagentStop", "Interrupt"
    ]

    public static func documented(for host: HookHost) -> [String] {
        switch host {
        case .claude: claude
        case .codex: codex
        default: []
        }
    }
}

/// Every reviewed change to one source file.
private struct SourceChange {
    struct Edit {
        let hook: AgentHook
        let handler: HookHandlerSpec
        let matcher: String?
        let changesMatcher: Bool
    }
    var precondition: HookFilePrecondition
    var host: HookHost
    var edits: [Edit] = []
    var appends: [(event: String, group: HookEditValue)] = []
    var removals: [AgentHook] = []
    var disableAll: Bool?
    /// Kiro list entries whose documented `enabled` member changes.
    var toggles: [(index: Int, enabled: Bool)] = []
    var notes: [String] = []
    var warnings: [String] = []

    var isRemovalOnly: Bool {
        edits.isEmpty && appends.isEmpty && disableAll == nil && toggles.isEmpty
    }
}

/// Add, edit, and `disableAllHooks` changes to documented standalone sources (ADR-0014 rule 2).
/// Every change to one file becomes one `replace-hook-source` command, applied in a fixed
/// order (in-place edits, appended groups, toggles, removals, then `disableAllHooks`) so that a
/// saved plan replays to the same bytes during execution preflight.
extension HookCleanupPlanner {
    static let editActions: Set<String> = ["add", "edit", "set-disable-all", "set-hook-enabled"]
    static let editRuleID = "hook-edit"
    private static let updatePrefix = "Update hooks in "

    /// True for a `replace-hook-source` command (by its display string) that adds or edits
    /// definitions rather than only removing them.
    public static func changesDefinitions(displayString: String) -> Bool {
        displayString.hasPrefix(updatePrefix)
    }

    /// The current `disableAllHooks` value of a Claude Code settings file.
    public static func disableAllHooks(atPath path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return false }
        return value["disableAllHooks"]?.boolValue == true
    }

    /// The source file an `add` or `set-disable-all` request writes, when the request is valid.
    public func targetPath(for request: HookCleanupRequest) -> String? {
        switch request.action {
        case "add":
            return try? addPath(
                host: editableHost(request.host), scope: request.scope, root: request.scopeRoot)
        case "set-disable-all":
            return disableAllHost(forPath: request.path) == nil ? nil : request.path
        default:
            return nil
        }
    }

    /// Stable identity of a queued edit; saved in the batch so preflight can replay it.
    public static func reference(for request: HookCleanupRequest) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(request)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    func sourceCommands(
        removals: [AgentHook], edits: [HookCleanupRequest], inventory: HookInventory
    ) throws -> [BatchCommand] {
        var changes: [String: SourceChange] = [:]
        for hook in removals {
            let condition = HookFilePrecondition(
                path: hook.source.path, contentHash: hook.source.contentHash,
                resolvedPath: hook.source.resolvedPath)
            let empty = SourceChange(precondition: condition, host: hook.source.host)
            changes[hook.source.path, default: empty].removals.append(hook)
        }
        var touched = Set(removals.map(\.id))
        for request in edits {
            try stage(request, inventory: inventory, touched: &touched, into: &changes)
        }
        return try changes.keys.sorted().map { path in
            let change = changes[path]!
            return change.isRemovalOnly
                ? try removalCommand(path: path, hooks: change.removals)
                : try updateCommand(path: path, change: change)
        }
    }

    func editReference(_ request: HookCleanupRequest, inventory: HookInventory) -> FindingRef {
        let root =
            inventory.hooks.first { $0.id == request.hookID }?.source.scopeRoot
            ?? request.scopeRoot ?? editRoot(forPath: request.path) ?? environment.home
        return FindingRef(
            findingID: Self.reference(for: request), ruleID: Self.editRuleID, skillName: nil,
            workspaceID: root == environment.home ? "user" : "project:" + root)
    }

    private func stage(
        _ request: HookCleanupRequest, inventory: HookInventory, touched: inout Set<String>,
        into changes: inout [String: SourceChange]
    ) throws {
        switch request.action {
        case "add":
            let host = try editableHost(request.host)
            let path = try addPath(host: host, scope: request.scope, root: request.scopeRoot)
            let event = try validatedEvent(request.event, host: host)
            let handler = try validatedHandler(request.handler, host: host)
            let matcher = normalized(request.matcher)
            var change =
                try changes[path] ?? newChange(path: path, host: host, inventory: inventory)
            change.appends.append((event.name, group(matcher: matcher, handler: rendered(handler))))
            change.notes.append(
                "Add \(event.name) handler" + (matcher.map { " for \($0)" } ?? "") + ": "
                    + handler.command)
            change.warnings += event.warning.map { [$0] } ?? []
            changes[path] = change
        case "edit":
            try stageEdit(request, inventory: inventory, touched: &touched, into: &changes)
        case "set-disable-all":
            guard let path = request.path, let flag = request.disableAllHooks,
                let host = disableAllHost(forPath: path)
            else {
                throw HookError(
                    "disableAllHooks applies to Claude Code, OpenClaude, Qwen Code, and Copilot CLI files only"
                )
            }
            var change =
                try changes[path] ?? newChange(path: path, host: host, inventory: inventory)
            guard change.disableAll == nil, Self.disableAllHooks(atPath: path) != flag else {
                throw HookError("disableAllHooks already has this value in " + path)
            }
            change.disableAll = flag
            change.notes.append(flag ? "Set disableAllHooks to true" : "Remove disableAllHooks")
            changes[path] = change
        case "set-hook-enabled":
            try stageToggle(request, inventory: inventory, touched: &touched, into: &changes)
        default: throw HookError("Unsupported hook cleanup action")
        }
    }

    /// Kiro documents `hooks[].enabled: false` to skip one hook without deleting it.
    private func stageToggle(
        _ request: HookCleanupRequest, inventory: HookInventory, touched: inout Set<String>,
        into changes: inout [String: SourceChange]
    ) throws {
        guard let hook = inventory.hooks.first(where: { $0.id == request.hookID }),
            let flag = request.enabled
        else { throw HookError("Hook no longer exists; rescan and replan") }
        guard Self.togglesEntries(hook) else {
            throw HookError("Only Kiro list-form hooks have a documented per-hook switch")
        }
        guard touched.insert(hook.id).inserted else {
            throw HookError("A hook can have only one queued change")
        }
        guard Self.hookEnabled(hook) != flag else {
            throw HookError("The hook is already \(flag ? "enabled" : "disabled")")
        }
        let path = hook.source.path
        var change =
            try changes[path] ?? newChange(path: path, host: hook.source.host, inventory: inventory)
        change.toggles.append((hook.groupIndex, flag))
        change.notes.append(
            (flag ? "Enable " : "Disable ") + "\(hook.event) hook \(hook.groupIndex)")
        changes[path] = change
    }

    /// Whether a hook sits in a writable Kiro list, whose entries carry `enabled`.
    public static func togglesEntries(_ hook: AgentHook) -> Bool {
        guard hook.source.host == .kiro, hook.source.writable, hook.source.definitionRoot.isEmpty,
            let data = FileManager.default.contents(atPath: hook.source.path),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return false }
        return value["hooks"]?.arrayValue != nil
    }

    public static func hookEnabled(_ hook: AgentHook) -> Bool {
        hook.details["enabled"]?.boolValue != false
    }

    private func stageEdit(
        _ request: HookCleanupRequest, inventory: HookInventory, touched: inout Set<String>,
        into changes: inout [String: SourceChange]
    ) throws {
        guard let hook = inventory.hooks.first(where: { $0.id == request.hookID }) else {
            throw HookError("Hook no longer exists; rescan and replan")
        }
        guard touched.insert(hook.id).inserted else {
            throw HookError("A hook can have only one queued change")
        }
        guard hook.canRemove, [.claude, .codex].contains(hook.source.host),
            !hook.source.path.hasSuffix(".toml")
        else {
            throw HookError(
                "This hook source is read-only for edits; Codex config.toml hooks are remove-only")
        }
        guard hook.handlerType == "command" else {
            throw HookError("Only command handlers can be edited")
        }
        let handler = try validatedHandler(request.handler, host: hook.source.host)
        let matcher = normalized(request.matcher)
        let path = hook.source.path
        var change =
            try changes[path]
            ?? newChange(path: path, host: hook.source.host, inventory: inventory)
        let siblings = inventory.hooks.filter {
            $0.source.path == path && $0.event == hook.event && $0.groupIndex == hook.groupIndex
        }
        if matcher != hook.matcher && siblings.count > 1 {
            change.appends.append(
                (hook.event, group(matcher: matcher, handler: moved(hook, handler))))
            change.removals.append(hook)
        } else {
            change.edits.append(
                SourceChange.Edit(
                    hook: hook, handler: handler, matcher: matcher,
                    changesMatcher: matcher != hook.matcher))
        }
        change.notes.append(
            "Edit \(hook.event) group \(hook.groupIndex) handler \(hook.handlerIndex)"
                + (matcher.map { " (matcher \($0))" } ?? "") + ": " + handler.command)
        changes[path] = change
    }

    private func newChange(
        path: String, host: HookHost, inventory: HookInventory
    ) throws -> SourceChange {
        if let source = inventory.hooks.first(where: { $0.source.path == path })?.source {
            let condition = HookFilePrecondition(
                path: path, contentHash: source.contentHash, resolvedPath: source.resolvedPath)
            try condition.validate()
            return SourceChange(precondition: condition, host: host)
        }
        guard let kind = DefaultFileSystemProbe().entryKind(atPath: path) else {
            let absent = HookFilePrecondition(path: path, contentHash: HookFilePrecondition.absent)
            return SourceChange(precondition: absent, host: host)
        }
        guard kind == .file, FileManager.default.isWritableFile(atPath: path) else {
            throw HookError("Hook source is not a writable regular file: " + path)
        }
        let hash = HookInventoryReader.hash(try Data(contentsOf: URL(fileURLWithPath: path)))
        return SourceChange(
            precondition: HookFilePrecondition(path: path, contentHash: hash), host: host)
    }

    private func updateCommand(path: String, change: SourceChange) throws -> BatchCommand {
        try change.precondition.validate()
        let absent = change.precondition.contentHash == HookFilePrecondition.absent
        let original = absent ? nil : try Data(contentsOf: URL(fileURLWithPath: path))
        let replacement = try apply(change, to: original ?? HookJSONDocument.emptyDocument)
        guard replacement != original else {
            throw HookError("The change leaves \(path) as it is")
        }
        let removed = change.removals.map {
            "Remove \($0.event) group \($0.groupIndex) handler \($0.handlerIndex)"
        }
        let intent = "Update \(path): " + (change.notes + removed).joined(separator: "; ")
        var warnings = [intent] + change.warnings
        if change.host == .codex {
            warnings.append(
                "Codex asks you to review and trust new or changed hooks before they run.")
        }
        if change.removals.contains(where: { $0.attribution.producerPresent == true }) {
            warnings.append("The installed producer may regenerate removed hooks.")
        }
        let argv = [
            "sukiru-fileop", "replace-hook-source", path, change.precondition.contentHash,
            replacement.base64EncodedString()
        ]
        let flags: [DangerFlag] =
            (change.removals.isEmpty ? [] : [.dangerousDeletion]) + [.directFileOperation]
        return BatchCommand(
            argv: argv, displayString: Self.updatePrefix + path, owningCLI: .file, intent: intent,
            dangerFlags: flags, warning: warnings.joined(separator: " "), captureRoots: [path],
            hookPreconditions: [change.precondition])
    }

    private func apply(_ change: SourceChange, to original: Data) throws -> Data {
        var data = original
        for edit in change.edits {
            let group: [HookJSONDocument.Step] = [
                .key("hooks"), .key(edit.hook.event), .index(edit.hook.groupIndex)
            ]
            let handler = group + [.key("hooks"), .index(edit.hook.handlerIndex)]
            data = try HookJSONDocument(data).setting(
                "command", to: .string(edit.handler.command), at: handler)
            data = try HookJSONDocument(data).setting(
                "timeout", to: edit.handler.timeout.map { .int($0) }, at: handler)
            if change.host == .codex {
                data = try HookJSONDocument(data).setting(
                    "statusMessage", to: edit.handler.statusMessage.map { .string($0) },
                    at: handler)
            }
            if edit.changesMatcher {
                data = try HookJSONDocument(data).setting(
                    "matcher", to: edit.matcher.map { .string($0) }, at: group, first: true)
            }
        }
        for append in change.appends {
            data = try HookJSONDocument(data).appendingGroup(
                event: append.event, group: append.group)
        }
        // Toggles address scanned list indices, which a removal would shift.
        for toggle in change.toggles {
            data = try HookJSONDocument(data).setting(
                "enabled", to: toggle.enabled ? nil : .bool(false),
                at: [.key("hooks"), .index(toggle.index)])
        }
        if !change.removals.isEmpty {
            data = try HookJSONDocument(data).removing(change.removals)
        }
        if let flag = change.disableAll {
            data = try HookJSONDocument(data).setting(
                "disableAllHooks", to: flag ? .bool(true) : nil, at: [])
        }
        return data
    }
}
