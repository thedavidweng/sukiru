import Foundation

extension HookInventoryReader {
    struct SourceDescriptor {
        let host: PluginHost
        let path: String
        let tier: String
        let scope: String
        let scopeRoot: String
        var pluginID: String?
        var managingSource: String?
        var prefix: [String] = []
        var tomlPreferenceKey: String?

        func source(hash: String) -> HookSource {
            HookSource(
                host: host, path: path, tier: tier,
                definitionRoot: prefix + (tomlPreferenceKey.map { [$0] } ?? []),
                scope: scope, scopeRoot: scopeRoot,
                managingPluginID: pluginID, managingSource: managingSource, contentHash: hash,
                resolvedPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
                writable: ["user", "project", "local"].contains(tier)
                    && !path.hasSuffix(".md") && prefix.isEmpty
                    && FileManager.default.isWritableFile(atPath: path)
                    && DefaultFileSystemProbe().entryKind(atPath: path) == .file)
        }
    }

    func sources(_ request: ScanRequest, plugins: PluginInventory) -> [SourceDescriptor] {
        let roots = request.explicitRoots.isEmpty ? environment.projectRoots : request.explicitRoots
        var result: [SourceDescriptor] = []
        if request.scope != .project {
            let claude =
                environment.externalValue(for: "CLAUDE_CONFIG_DIR") ?? environment.home + "/.claude"
            let codex = environment.externalValue(for: "CODEX_HOME") ?? environment.home + "/.codex"
            result += standalone(
                claude: claude, codex: codex, scope: "user", root: environment.home)
            result += markdownSources(
                claude + "/skills", tier: "skill", root: environment.home, scope: "user")
            result += markdownSources(
                environment.home + "/.agents/skills", tier: "skill", root: environment.home,
                scope: "user")
            result += markdownSources(
                claude + "/agents", tier: "subagent", root: environment.home, scope: "user")
            result += managedSources()
        }
        if request.scope != .user {
            for root in Set(roots).sorted() {
                result += standalone(
                    claude: root + "/.claude", codex: root + "/.codex", scope: "project", root: root
                )
                result.append(
                    SourceDescriptor(
                        host: .claude, path: root + "/.claude/settings.local.json", tier: "local",
                        scope: "local", scopeRoot: root))
                result += markdownSources(
                    root + "/.claude/skills", tier: "skill", root: root, scope: "project")
                result += markdownSources(
                    root + "/.agents/skills", tier: "skill", root: root, scope: "project")
                result += markdownSources(
                    root + "/.claude/agents", tier: "subagent", root: root, scope: "project")
            }
        }
        result += installedSources(plugins.installations)
        var seen: Set<String> = []
        return result.filter {
            seen.insert(
                [
                    $0.host.rawValue, $0.path, $0.scopeRoot, $0.prefix.joined(separator: "."),
                    $0.tomlPreferenceKey ?? ""
                ].joined(
                    separator: ":")
            ).inserted
        }
    }

    private func installedSources(_ plugins: [PluginInstallation]) -> [SourceDescriptor] {
        var result: [SourceDescriptor] = []
        for plugin in plugins where plugin.host != .opencode {
            guard let path = plugin.path else { continue }
            result += pluginSources(plugin, path: path)
            for component in plugin.components
            where plugin.host == .claude && ["skills", "agents"].contains(component.kind) {
                guard let path = component.path else { continue }
                let markdown = component.kind == "skills" ? path + "/SKILL.md" : path
                result.append(
                    SourceDescriptor(
                        host: plugin.host, path: markdown,
                        tier: component.kind == "skills" ? "skill" : "subagent",
                        scope: plugin.scope,
                        scopeRoot: plugin.scopeRoot, pluginID: plugin.id, managingSource: path))
            }
        }
        return result
    }

    private func managedSources() -> [SourceDescriptor] {
        var result: [SourceDescriptor] = []
        if let systemRoot = environment.systemRoot {
            result += [
                SourceDescriptor(
                    host: .claude,
                    path: HostPathResolver.join(
                        systemRoot, "Library/Application Support/ClaudeCode/managed-settings.json"),
                    tier: "managed", scope: "managed", scopeRoot: environment.home),
                SourceDescriptor(
                    host: .codex, path: HostPathResolver.join(systemRoot, "etc/codex/config.toml"),
                    tier: "managed",
                    scope: "managed", scopeRoot: environment.home),
                SourceDescriptor(
                    host: .codex, path: HostPathResolver.join(systemRoot, "etc/codex/hooks.json"),
                    tier: "managed",
                    scope: "managed", scopeRoot: environment.home),
                SourceDescriptor(
                    host: .codex,
                    path: HostPathResolver.join(systemRoot, "etc/codex/requirements.toml"),
                    tier: "managed",
                    scope: "managed", scopeRoot: environment.home)
            ]
            let policy = HostPathResolver.join(
                systemRoot, "Library/Application Support/ClaudeCode/managed-settings.d")
            for name in entries(policy) where name.hasSuffix(".json") && !name.hasPrefix(".") {
                result.append(
                    SourceDescriptor(
                        host: .claude, path: policy + "/" + name,
                        tier: "managed", scope: "managed", scopeRoot: environment.home))
            }
            result += preferenceSources(systemRoot: systemRoot)
        }
        return result
    }

    private func preferenceSources(systemRoot: String) -> [SourceDescriptor] {
        let base = HostPathResolver.join(systemRoot, "Library/Managed Preferences")
        var result = [
            SourceDescriptor(
                host: .claude,
                path: base + "/com.anthropic.claudecode.plist", tier: "managed",
                scope: "managed", scopeRoot: environment.home)
        ]
        for key in ["config_toml_base64", "requirements_toml_base64"] {
            result.append(
                SourceDescriptor(
                    host: .codex, path: base + "/com.openai.codex.plist",
                    tier: "managed", scope: "managed", scopeRoot: environment.home,
                    tomlPreferenceKey: key))
        }
        return result
    }

    private func standalone(
        claude: String, codex: String, scope: String, root: String
    ) -> [SourceDescriptor] {
        [
            SourceDescriptor(
                host: .claude, path: claude + "/settings.json", tier: scope, scope: scope,
                scopeRoot: root),
            SourceDescriptor(
                host: .codex, path: codex + "/hooks.json", tier: scope, scope: scope,
                scopeRoot: root),
            SourceDescriptor(
                host: .codex, path: codex + "/config.toml", tier: scope, scope: scope,
                scopeRoot: root)
        ]
    }

    private func markdownSources(
        _ directory: String, tier: String, root: String, scope: String
    ) -> [SourceDescriptor] {
        entries(directory).compactMap { name in
            let path = directory + "/" + name + (tier == "skill" ? "/SKILL.md" : "")
            guard tier == "skill" || name.hasSuffix(".md") else { return nil }
            return SourceDescriptor(
                host: .claude, path: path, tier: tier, scope: scope,
                scopeRoot: root, managingSource: path)
        }
    }

    private func pluginSources(_ plugin: PluginInstallation, path: String) -> [SourceDescriptor] {
        let candidates =
            plugin.host == .claude
            ? [".claude-plugin/plugin.json"]
            : [
                "plugin.json", ".codex-plugin/plugin.json", ".claude-plugin/plugin.json",
                ".cursor-plugin/plugin.json"
            ]
        let manifest = candidates.map { path + "/" + $0 }.first {
            FileManager.default.fileExists(atPath: $0)
        }
        let defaultSource = SourceDescriptor(
            host: plugin.host, path: path + "/hooks/hooks.json", tier: "plugin",
            scope: plugin.scope, scopeRoot: plugin.scopeRoot, pluginID: plugin.id)
        guard let manifest else { return [defaultSource] }
        let descriptor = SourceDescriptor(
            host: plugin.host, path: manifest, tier: "plugin",
            scope: plugin.scope, scopeRoot: plugin.scopeRoot, pluginID: plugin.id)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: manifest)),
            let object = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return [descriptor] }
        guard let hooks = object["hooks"] else { return [defaultSource] }
        let values = hooks.arrayValue ?? [hooks]
        return values.enumerated().compactMap { index, value in
            if let relative = value.stringValue {
                let target = URL(fileURLWithPath: path).appendingPathComponent(relative)
                    .standardizedFileURL.resolvingSymlinksInPath().path
                let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                guard target.hasPrefix(root + "/") else { return descriptor }
                return SourceDescriptor(
                    host: plugin.host, path: target, tier: "plugin", scope: plugin.scope,
                    scopeRoot: plugin.scopeRoot, pluginID: plugin.id)
            }
            var inline = descriptor
            inline.prefix = ["hooks"] + (hooks.arrayValue == nil ? [] : [String(index)])
            return inline
        }
    }

    private func entries(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path))?.sorted() ?? []
    }
}
