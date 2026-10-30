import Foundation

public enum ExtensionAction: String, Codable, CaseIterable, Sendable {
    case remove
    case disable
    case enable
}

/// How one add-on change runs, in ADR-0014's order: the host's own command when its CLI is
/// installed and its help shows the subcommand, else a documented configuration edit, else
/// instructions. Every command and key is sourced in docs/agent-interface-sources.md.
struct AgentExtensionRoutes {
    enum Route {
        case commands([BatchCommand])
        case instructions(String)
    }

    let environment: SukiruEnvironment
    private let probe: HostHelpProbe

    init(environment: SukiruEnvironment) {
        self.environment = environment
        probe = HostHelpProbe(environment: environment)
    }

    func route(_ item: AgentExtension, _ action: ExtensionAction) throws -> Route {
        switch item.category {
        case .autoloaded: try autoloaded(item, action)
        case .package: try package(item, action)
        case .plugin: try plugin(item, action)
        case .mcpServer: try mcpServer(item, action)
        }
    }

    /// The reason a host offers no switch for this entry, without probing any CLI.
    static func toggleLimit(_ item: AgentExtension) -> String? {
        switch (item.host, item.category) {
        case (.dsh, _):
            "DSH enables and disables bundle plugins in its plugin panel (Settings → Plugins)."
        case (.devin, .plugin): "Devin has no plugin disable; remove the plugin instead."
        case (.claude, .mcpServer), (.openclaude, .mcpServer):
            "\(item.host.rawValue) has no documented user-scope MCP switch; toggle it in /mcp."
        default: nil
        }
    }

    // MARK: - categories

    private func autoloaded(_ item: AgentExtension, _ action: ExtensionAction) throws -> Route {
        let reader = AgentExtensionReader(environment: environment)
        if action == .remove {
            let hermes = ["hermes", "plugins", "remove", item.name]
            let command =
                item.host == .hermes && item.kind == .directory
                ? native(item, hermes, help: 3) : nil
            return .commands([command ?? AgentExtensionMutation.command(item)])
        }
        let disable = action == .disable
        switch item.host {
        case .pi:
            let settings = reader.piAgentDir + "/settings.json"
            let forms = AutoloadStates.piExclusions(item.name, agentDir: reader.piAgentDir)
            let present = HostConfigFile.json(settings)?.strings(at: ["extensions"]) ?? []
            let edits: [AgentConfigEdit] =
                disable
                ? [.jsonItem(keys: ["extensions"], item: forms[0], present: true)]
                : forms.filter(present.contains).map {
                    .jsonItem(keys: ["extensions"], item: $0, present: false)
                }
            return .commands([try edit(item, path: settings, edits, action)])
        case .omp:
            return try ompToggle(item, action, configPath: reader.ompAgentDir + "/config.yml")
        case .hermes:
            let argv = ["hermes", "plugins", action.rawValue, item.name]
            if let command = native(item, argv, help: 3) { return .commands([command]) }
            let edits: [AgentConfigEdit] = [
                .yamlItem(keys: ["plugins", "enabled"], item: item.name, present: !disable),
                .yamlItem(keys: ["plugins", "disabled"], item: item.name, present: disable)
            ]
            return .commands([
                try edit(item, path: reader.hermesHome + "/config.yaml", edits, action)
            ])
        default:
            return .commands([
                try AgentExtensionMutation.moveCommand(item, disable: disable, reader: reader)
            ])
        }
    }

    private func package(_ item: AgentExtension, _ action: ExtensionAction) throws -> Route {
        if item.host == .dsh {
            guard action == .remove, let profile = item.scopeName else {
                return .instructions(Self.toggleLimit(item)!)
            }
            let argv = ["dsh", "plugin", "--profile", profile, "remove", item.name]
            guard let command = native(item, argv, help: 2, verb: "remove") else {
                return .instructions(
                    "Install the dsh CLI, then run `\(argv.joined(separator: " "))`.")
            }
            return .commands([command])
        }
        if action == .remove, let command = native(item, ["pi", "remove", item.name], help: 2) {
            return .commands([command])
        }
        return .commands([
            try edit(item, path: item.path, [.piPackage(source: item.name, change: action)], action)
        ])
    }

    private func plugin(_ item: AgentExtension, _ action: ExtensionAction) throws -> Route {
        switch (item.host, action) {
        case (.droid, .remove):
            return nativeOrHint(
                item, ["droid", "plugin", "uninstall", item.name, "--scope", "user"], help: 3)
        case (.droid, _):
            return .commands([
                try edit(
                    item, path: item.path,
                    [
                        .jsonMember(
                            keys: ["enabledPlugins", item.name], value: .bool(action == .enable))
                    ], action)
            ])
        case (.openclaude, _):
            let verb = action == .remove ? "uninstall" : action.rawValue
            let argv = ["openclaude", "plugin", verb, item.name, "--scope", "user"]
            if let command = native(item, argv, help: 3) { return .commands([command]) }
            guard action != .remove else { return nativeOrHint(item, argv, help: 3) }
            return .commands([
                try edit(
                    item, path: environment.home + "/.openclaude/settings.json",
                    [
                        .jsonMember(
                            keys: ["enabledPlugins", item.name], value: .bool(action == .enable))
                    ], action)
            ])
        case (.devin, .remove):
            return nativeOrHint(
                item, ["devin", "plugins", "remove", item.name, "-y"], help: 3)
        default:
            return .instructions(Self.toggleLimit(item) ?? "No documented switch for this plugin.")
        }
    }

    private func mcpServer(_ item: AgentExtension, _ action: ExtensionAction) throws -> Route {
        let cli = mcpCLI(item, action)
        if let cli, let command = native(item, cli, help: 3) { return .commands([command]) }
        // A file edit creates missing parents, so a server removed since the scan would return.
        let current = FileManager.default.contents(atPath: item.path).map(HookInventoryReader.hash)
        guard current == item.contentHash else {
            throw HookError(item.path + " changed since the scan; rescan and replan")
        }
        if let edits = try mcpEdits(item, action) {
            return .commands([try edit(item, path: item.path, edits, action)])
        }
        let hint =
            "Install the \(item.host.rawValue) CLI, then run `\((cli ?? []).joined(separator: " "))`."
        return .instructions(Self.toggleLimit(item) ?? hint)
    }

    private func mcpCLI(_ item: AgentExtension, _ action: ExtensionAction) -> [String]? {
        let remove = action == .remove
        return switch item.host {
        case .claude, .openclaude:
            remove ? [item.host.rawValue, "mcp", "remove", item.name, "--scope", "user"] : nil
        case .codex, .hermes:
            remove ? [item.host.rawValue, "mcp", "remove", item.name] : nil
        case .gemini: ["gemini", "mcp", action.rawValue, item.name]
        case .droid: remove ? ["droid", "mcp", "remove", item.name] : nil
        case .grok: ["grok", "mcp", action.rawValue, item.name]
        case .devin: ["devin", "mcp", action.rawValue, item.name, "--scope", "user"]
        case .cursor: remove ? nil : ["cursor-agent", "mcp", action.rawValue, item.name]
        default: nil
        }
    }

    /// The documented file edit, or nil when the host's file has no per-server switch.
    private func mcpEdits(
        _ item: AgentExtension, _ action: ExtensionAction
    ) throws -> [AgentConfigEdit]? {
        let keys =
            (item.scopeName ?? "mcpServers").split(separator: ".").map(String.init) + [item.name]
        let remove = action == .remove
        let disable = action == .disable
        switch item.host {
        case .codex, .grok:
            return remove
                ? [.tomlRemove(server: item.name)]
                : [.tomlEnabled(server: item.name, value: !disable)]
        case .hermes:
            return remove
                ? [.yamlRemove(keys: keys)] : [.yamlBool(keys: keys + ["enabled"], value: !disable)]
        case .gemini:
            return remove
                ? [.jsonMember(keys: keys, value: nil)]
                : [.jsonItem(keys: ["mcp", "excluded"], item: item.name, present: disable)]
        case .droid:
            return [
                .jsonMember(
                    keys: remove ? keys : keys + ["disabled"], value: disable ? .bool(true) : nil)
            ]
        case .muse, .omp, .opencode:
            return [
                .jsonMember(
                    keys: remove ? keys : keys + ["enabled"], value: disable ? .bool(false) : nil)
            ]
        case .claude, .openclaude, .cursor, .devin:
            return remove ? [.jsonMember(keys: keys, value: nil)] : nil
        default:
            throw HookError("No MCP route for " + item.host.rawValue)
        }
    }

    // MARK: - commands

    private func nativeOrHint(_ item: AgentExtension, _ argv: [String], help: Int) -> Route {
        native(item, argv, help: help).map { .commands([$0]) }
            ?? .instructions(
                "Install the \(argv[0]) CLI, then run `\(argv.joined(separator: " "))`.")
    }

    /// The host command when its CLI is installed and \`<argv[..<help]> --help\` mentions
    /// \`verb\` (default: the command's last subcommand word).
    private func native(
        _ item: AgentExtension, _ argv: [String], help: Int, verb: String? = nil
    ) -> BatchCommand? {
        let word = verb ?? argv[help - 1]
        guard let owner = OwningCLI(rawValue: argv[0] == "cursor-agent" ? "cursor" : argv[0]),
            probe.mentions(argv[0], Array(argv[1..<max(help, 1)]), word)
        else { return nil }
        let intent = "\(Self.verb(argv)) \(item.name) with the \(argv[0]) CLI"
        return BatchCommand(
            argv: argv, displayString: BatchCommand.display(for: argv), owningCLI: owner,
            intent: intent,
            dangerFlags: argv.contains(where: ["remove", "uninstall"].contains)
                ? [.dangerousDeletion] : [],
            warning: intent + ". File rollback restores only the captured files: "
                + captureRoots(item).joined(separator: ", "),
            captureRoots: captureRoots(item))
    }

    private static func verb(_ argv: [String]) -> String {
        if argv.contains("disable") { return "Disable" }
        if argv.contains("enable") { return "Enable" }
        return "Remove"
    }

    /// Files a host command may change: the declaring file plus the payload it manages.
    private func captureRoots(_ item: AgentExtension) -> [String] {
        let home = environment.home
        var roots = [item.path]
        switch (item.host, item.category) {
        case (.hermes, .autoloaded): roots.append(home + "/.hermes/config.yaml")
        case (.pi, _):
            roots.append(
                AgentExtensionReader(environment: environment).piAgentDir + "/settings.json")
        case (.dsh, _):
            let profile = URL(fileURLWithPath: item.path).deletingLastPathComponent().path
            roots += [profile + "/pnpm-lock.yaml", profile + "/cordis.patch.yml"]
        case (.droid, .plugin): roots.append(home + "/.factory/plugins")
        case (.openclaude, .plugin): roots.append(home + "/.openclaude/settings.json")
        case (.devin, .plugin): roots.append(home + "/.local/share/devin/cli/plugins")
        default: break
        }
        return Array(Set(roots)).sorted()
    }

    private func edit(
        _ item: AgentExtension, path: String, _ edits: [AgentConfigEdit], _ action: ExtensionAction
    ) throws -> BatchCommand {
        try AgentExtensionMutation.editCommand(
            path: path, edits: edits,
            intent: "\(action.rawValue.capitalized) \(item.name) in \(path)")
    }
}

extension AgentExtensionRoutes {
    /// omp keys a switch by file stem, so one entry is switched only when no sibling shares it.
    fileprivate func ompToggle(
        _ item: AgentExtension, _ action: ExtensionAction, configPath: String
    ) throws -> Route {
        let id = AutoloadStates.ompID(item.name)
        let directory = URL(fileURLWithPath: item.path).deletingLastPathComponent().path
        let siblings = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { AutoloadStates.ompID($0) == id }.sorted()
        guard siblings.count == 1 else {
            let names = siblings.joined(separator: ", ")
            return .instructions("omp switches \(id) for \(names) together; rename one first.")
        }
        let edits: [AgentConfigEdit] = [
            .yamlItem(keys: ["disabledExtensions"], item: id, present: action == .disable)
        ]
        return .commands([try edit(item, path: configPath, edits, action)])
    }
}

/// Runs \`<cli> <subcommands> --help\` once per command line. Probes only run while planning.
final class HostHelpProbe {
    private let probe: PluginLifecycleProbe
    private var cache: [[String]: String?] = [:]

    init(environment: SukiruEnvironment) { probe = PluginLifecycleProbe(environment: environment) }

    func mentions(_ executable: String, _ arguments: [String], _ word: String) -> Bool {
        let key = [executable] + arguments
        if cache[key] == nil {
            cache[key] = probe.help(executable: executable, arguments: arguments)
        }
        // Only a line that starts with the subcommand lists it; prose mentions do not.
        let lines = (cache[key] ?? nil)?.split(whereSeparator: \.isNewline) ?? []
        return lines.contains { line in
            line.split(whereSeparator: { " \t,|".contains($0) }).first.map(String.init) == word
        }
    }
}
