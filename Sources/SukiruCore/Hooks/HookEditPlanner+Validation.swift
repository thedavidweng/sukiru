import Foundation

/// Request validation, documented source paths, and rendered handler values for hook edits.
extension HookCleanupPlanner {
    func editableHost(_ host: HookHost?) throws -> HookHost {
        guard let host, [.claude, .codex].contains(host) else {
            throw HookError("Hooks can be added for Claude Code or Codex only")
        }
        return host
    }

    /// The documented standalone file for a host and scope; Codex has no local scope.
    func addPath(host: HookHost, scope: String?, root: String?) throws -> String {
        let scope = scope ?? "user"
        switch scope {
        case "user":
            guard root == nil || root == environment.home else {
                throw HookError("User scope belongs to the home directory")
            }
            return host == .claude
                ? claudeDirectory + "/settings.json" : codexDirectory + "/hooks.json"
        case "project", "local":
            guard let root, environment.projectRoots.contains(root) else {
                throw HookError("Add the project to Sukiru before adding project hooks")
            }
            guard scope == "project" || host == .claude else {
                throw HookError("Codex has no local hook scope")
            }
            if host == .codex { return root + "/.codex/hooks.json" }
            return root
                + (scope == "local" ? "/.claude/settings.local.json" : "/.claude/settings.json")
        default:
            throw HookError("Unsupported hook scope: " + scope)
        }
    }

    /// The scope root of a writable Claude Code settings file, or nil for any other path.
    func editRoot(forPath path: String?) -> String? {
        guard let path else { return nil }
        if path == claudeDirectory + "/settings.json" { return environment.home }
        return environment.projectRoots.first {
            path == $0 + "/.claude/settings.json" || path == $0 + "/.claude/settings.local.json"
        }
    }

    /// The host of a file that documents a top-level `disableAllHooks` switch.
    public func disableAllHost(forPath path: String?) -> HookHost? {
        guard let path else { return nil }
        if editRoot(forPath: path) != nil { return .claude }
        let home = environment.home
        if path == home + "/.openclaude/settings.json" { return .openclaude }
        if path == home + "/.qwen/settings.json" { return .qwenCode }
        let copilot =
            (environment.externalValue(for: "COPILOT_HOME") ?? home + "/.copilot") + "/hooks/"
        let name = path.hasPrefix(copilot) ? path.dropFirst(copilot.count) : ""
        return name.hasSuffix(".json") && !name.contains("/") ? .copilot : nil
    }

    private var claudeDirectory: String {
        environment.externalValue(for: "CLAUDE_CONFIG_DIR") ?? environment.home + "/.claude"
    }

    private var codexDirectory: String {
        environment.externalValue(for: "CODEX_HOME") ?? environment.home + "/.codex"
    }

    func validatedEvent(_ event: String?, host: HookHost) throws -> (
        name: String, warning: String?
    ) {
        guard let event, let first = event.first, first.isLetter,
            event.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { throw HookError("Choose a hook event") }
        if HookEvents.documented(for: host).contains(event) { return (event, nil) }
        guard host == .codex else {
            throw HookError("Claude Code does not document the hook event " + event)
        }
        return (event, "Codex does not document the hook event \(event); verify it in Codex.")
    }

    func validatedHandler(
        _ handler: HookHandlerSpec?, host: HookHost
    ) throws -> HookHandlerSpec {
        guard let handler, handler.type == "command" else {
            throw HookError("Only command handlers can be added or edited")
        }
        guard !handler.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HookError("Enter the hook command")
        }
        guard handler.timeout.map({ $0 > 0 }) ?? true else {
            throw HookError("The hook timeout must be a positive number of seconds")
        }
        let status = handler.statusMessage.flatMap { $0.isEmpty ? nil : $0 }
        guard status == nil || host == .codex else {
            throw HookError("statusMessage is a Codex handler field")
        }
        return HookHandlerSpec(
            command: handler.command, timeout: handler.timeout, statusMessage: status)
    }

    func normalized(_ matcher: String?) -> String? {
        guard let matcher, !matcher.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        return matcher
    }

    func rendered(_ handler: HookHandlerSpec) -> [(String, HookEditValue)] {
        [("type", .string(handler.type)), ("command", .string(handler.command))]
            + (handler.timeout.map { [("timeout", .int($0))] } ?? [])
            + (handler.statusMessage.map { [("statusMessage", .string($0))] } ?? [])
    }

    /// The edited handler for its new group, keeping fields the form does not manage.
    func moved(_ hook: AgentHook, _ handler: HookHandlerSpec) -> [(
        String, HookEditValue
    )] {
        let managed: Set<String> = ["type", "command", "timeout", "statusMessage"]
        var fields = rendered(handler)
        if hook.source.host == .claude, let status = hook.details["statusMessage"] {
            fields.append(("statusMessage", HookEditValue(status)))
        }
        return fields
            + hook.details.keys.sorted().filter { !managed.contains($0) }.map {
                ($0, HookEditValue(hook.details[$0]!))
            }
    }

    func group(matcher: String?, handler: [(String, HookEditValue)]) -> HookEditValue {
        .object(
            (matcher.map { [("matcher", .string($0))] } ?? []) + [
                ("hooks", .array([.object(handler)]))
            ])
    }
}
