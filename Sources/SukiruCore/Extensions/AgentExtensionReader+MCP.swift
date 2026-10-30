import Foundation

/// User-scope MCP server declarations, read from each host's documented configuration file.
extension AgentExtensionReader {
    enum MCPFormat { case json, toml, yaml }

    /// How a host records that one server is off.
    enum MCPSwitch {
        /// No documented per-server switch in this file.
        case none
        /// \`enabled: false\` keeps the entry but never starts it.
        case enabledKey
        /// \`disabled: true\`.
        case disabledKey
        /// Gemini CLI's \`mcp.excluded\` name list.
        case excludedList
    }

    struct MCPSource {
        let host: ExtensionHost
        let path: String
        let keys: [String]
        let format: MCPFormat
        let toggle: MCPSwitch

        init(
            _ host: ExtensionHost, _ path: String, key: String = "mcpServers",
            format: MCPFormat = .json, toggle: MCPSwitch = .none
        ) {
            self.host = host
            self.path = path
            keys = [key]
            self.format = format
            self.toggle = toggle
        }
    }

    func mcpSources() -> [MCPSource] {
        let home = environment.home
        let codex = environment.externalValue(for: "CODEX_HOME") ?? home + "/.codex"
        let muse = configHome + "/muse/settings.json"
        return [
            MCPSource(.claude, home + "/.claude.json"),
            MCPSource(.openclaude, home + "/.openclaude.json"),
            MCPSource(.cursor, home + "/.cursor/mcp.json"),
            MCPSource(.droid, home + "/.factory/mcp.json", toggle: .disabledKey),
            MCPSource(.devin, configHome + "/devin/mcp_config.json"),
            MCPSource(.muse, muse, toggle: .enabledKey),
            MCPSource(.muse, muse, key: "mcp_servers", toggle: .enabledKey),
            MCPSource(.omp, ompAgentDir + "/mcp.json", toggle: .enabledKey),
            MCPSource(.gemini, home + "/.gemini/settings.json", toggle: .excludedList),
            MCPSource(.opencode, openCodeDir + "/opencode.json", key: "mcp", toggle: .enabledKey),
            MCPSource(
                .codex, codex + "/config.toml", key: "mcp_servers", format: .toml,
                toggle: .enabledKey),
            MCPSource(
                .grok, home + "/.grok/config.toml", key: "mcp_servers", format: .toml,
                toggle: .enabledKey),
            MCPSource(
                .hermes, hermesHome + "/config.yaml", key: "mcp_servers", format: .yaml,
                toggle: .enabledKey)
        ]
    }

    func mcpServers() -> [AgentExtension] {
        mcpSources().flatMap { source -> [AgentExtension] in
            guard let file = Self.read(source) else { return [] }
            let excluded = Set(file.strings(at: ["mcp", "excluded"]))
            let persisted = source.toggle == .excludedList ? geminiEnablement() : [:]
            return (file.value(at: source.keys)?.objectValue ?? [:]).sorted { $0.key < $1.key }
                .map { name, server in
                    let enabled: Bool? =
                        switch source.toggle {
                        case .none: nil
                        case .enabledKey: server["enabled"]?.boolValue ?? true
                        case .disabledKey: !(server["disabled"]?.boolValue ?? false)
                        case .excludedList:
                            !excluded.contains(name)
                                && persisted[name.lowercased()]?["enabled"]?.boolValue != false
                        }
                    return configEntry(
                        source.host, .mcpServer, name: name, file: file, enabled: enabled,
                        detail: Self.endpoint(server), scopeName: source.keys.joined(separator: ".")
                    )
                }
        }
    }

    /// `gemini mcp disable` persists `{"<lowercased name>": {"enabled": false}}` here.
    private func geminiEnablement() -> [String: JSONValue] {
        HostConfigFile.json(environment.home + "/.gemini/mcp-server-enablement.json")?.value
            .objectValue ?? [:]
    }

    static func read(_ source: MCPSource) -> HostConfigFile? {
        switch source.format {
        case .json: return HostConfigFile.json(source.path)
        case .yaml: return HostConfigFile.yaml(source.path)
        case .toml:
            guard let data = FileManager.default.contents(atPath: source.path),
                let text = String(bytes: data, encoding: .utf8)
            else { return nil }
            return HostConfigFile(
                path: source.path, hash: HookInventoryReader.hash(data),
                value: .object(["mcp_servers": .object(TOMLServerTables.servers(text))]))
        }
    }

    private static func endpoint(_ server: JSONValue) -> String? {
        if let url = server["url"]?.stringValue ?? server["httpUrl"]?.stringValue { return url }
        let command =
            (server["command"]?.stringValue.map { [$0] }
                ?? server["command"]?.arrayValue?
                .compactMap(\.stringValue)) ?? []
        let args = (server["args"]?.arrayValue ?? []).compactMap(\.stringValue)
        return command.isEmpty ? nil : (command + args).joined(separator: " ")
    }
}
