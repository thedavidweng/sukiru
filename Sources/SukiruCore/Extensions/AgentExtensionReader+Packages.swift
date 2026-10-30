import Foundation

/// Declared packages (Pi \`packages\`, DSH profile dependencies) and plugins of hosts without a
/// \`PluginHost\` lifecycle (Droid, OpenClaude, Devin), read from their documented records.
extension AgentExtensionReader {
    static let piPackageFilters = ["extensions", "skills", "prompts", "themes"]

    func packages() -> [AgentExtension] {
        piPackages() + dshPackages()
    }

    func plugins() -> [AgentExtension] {
        droidPlugins() + openClaudePlugins() + devinPlugins()
    }

    var dshHome: String { environment.home + "/.dsh" }

    /// A package disabled by Sukiru narrows every Pi resource filter to an empty list.
    private func piPackages() -> [AgentExtension] {
        guard let file = HostConfigFile.json(piAgentDir + "/settings.json") else { return [] }
        return (file.value["packages"]?.arrayValue ?? []).compactMap { element in
            guard let source = element.stringValue ?? element["source"]?.stringValue else {
                return nil
            }
            let disabled = Self.piPackageFilters.allSatisfy { element[$0]?.arrayValue == [] }
            return configEntry(
                .pi, .package, name: source, file: file, enabled: !disabled, detail: source)
        }
    }

    /// DSH installs bundle plugins as pnpm dependencies of a profile; \`@deepseek-ai/\` packages
    /// are the harness itself.
    private func dshPackages() -> [AgentExtension] {
        let profiles = dshHome + "/profiles"
        return entries(profiles).flatMap { profile -> [AgentExtension] in
            guard let file = HostConfigFile.json(profiles + "/" + profile + "/package.json")
            else { return [] }
            return (file.value["dependencies"]?.objectValue ?? [:]).keys.sorted()
                .filter { !$0.hasPrefix("@deepseek-ai/") }
                .map { name in
                    configEntry(
                        .dsh, .package, name: name, file: file, enabled: nil,
                        detail: file.value["dependencies"]?[name]?.stringValue, scopeName: profile)
                }
        }
    }

    /// Droid documents \`enabledPlugins\` as its user-scope enablement record.
    private func droidPlugins() -> [AgentExtension] {
        guard let file = HostConfigFile.json(environment.home + "/.factory/settings.json") else {
            return []
        }
        return (file.value["enabledPlugins"]?.objectValue ?? [:]).sorted { $0.key < $1.key }
            .map { id, value in
                configEntry(.droid, .plugin, name: id, file: file, enabled: value.boolValue)
            }
    }

    /// OpenClaude keeps Claude Code's \`installed_plugins.json\` and \`enabledPlugins\`.
    private func openClaudePlugins() -> [AgentExtension] {
        let root = environment.home + "/.openclaude"
        guard let file = HostConfigFile.json(root + "/plugins/installed_plugins.json") else {
            return []
        }
        let settings = HostConfigFile.json(root + "/settings.json")
        return (file.value["plugins"]?.objectValue ?? [:]).sorted { $0.key < $1.key }
            .compactMap { id, installs in
                let scopes = (installs.arrayValue ?? []).compactMap { $0["scope"]?.stringValue }
                guard scopes.contains("user") else { return nil }
                return configEntry(
                    .openclaude, .plugin, name: id, file: file,
                    enabled: settings?.value["enabledPlugins"]?[id]?.boolValue == true,
                    scopeName: "user")
            }
    }

    /// Devin resolves plugin requirements into \`lock.json\`; it has no disable state.
    private func devinPlugins() -> [AgentExtension] {
        let path = environment.home + "/.local/share/devin/cli/plugins/lock.json"
        guard let file = HostConfigFile.json(path) else { return [] }
        let requirements = file.value["requirements"]?.arrayValue ?? []
        return (file.value["resolved"]?.arrayValue ?? []).compactMap { resolved in
            guard let name = resolved["name"]?.stringValue else { return nil }
            let scope = requirements.first { $0["spec"] == resolved["spec"] }?["origin"]?["scope"]
            return configEntry(
                .devin, .plugin, name: name, file: file, enabled: nil,
                detail: resolved["identity"]?.stringValue, scopeName: scope?.stringValue)
        }
    }

    func configEntry(
        _ host: ExtensionHost, _ category: ExtensionCategory, name: String, file: HostConfigFile,
        enabled: Bool?, detail: String? = nil, scopeName: String? = nil
    ) -> AgentExtension {
        let producer = Self.producer(name)
        return AgentExtension(
            host: host, category: category, name: name, path: file.path, kind: .configEntry,
            producer: producer.name, evidence: producer.evidence, contentHash: file.hash,
            enabled: enabled, detail: detail, scopeName: scopeName)
    }
}
