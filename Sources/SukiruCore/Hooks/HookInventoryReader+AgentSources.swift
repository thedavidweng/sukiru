import Foundation

/// User-scope hook sources of agents whose hooks only third-party producers such as Orca
/// typically write. Paths and layouts follow each agent's documented configuration.
extension HookInventoryReader {
    func agentSources() -> [SourceDescriptor] {
        let home = environment.home
        func directory(_ key: String, _ fallback: String) -> String {
            environment.externalValue(for: key) ?? home + fallback
        }
        let files: [(HookHost, String)] = [
            (.openclaude, home + "/.openclaude/settings.json"),
            (.gemini, home + "/.gemini/settings.json"),
            (.cursor, home + "/.cursor/hooks.json"),
            (.droid, home + "/.factory/settings.json"),
            (.qoder, home + "/.qoder/settings.json"),
            (.qoderCN, home + "/.qoder-cn/settings.json"),
            (.qwenCode, home + "/.qwen/settings.json"),
            (.codebuddy, home + "/.codebuddy/settings.json"),
            (.commandCode, home + "/.commandcode/settings.json"),
            (.devin, home + "/.config/devin/config.json"),
            (.kimi, directory("KIMI_CODE_HOME", "/.kimi-code") + "/config.toml"),
            (.jcode, directory("JCODE_HOME", "/.jcode") + "/config.toml"),
            // DSH reads this file through its cordis patch layer; only Orca writes it.
            (.dsh, home + "/.orca/agent-hooks/dsh-hooks.json")
        ]
        var result = files.map { user($0.0, $0.1) }
        var zcode = user(.zcode, home + "/.zcode/cli/config.json")
        zcode.container = ["hooks", "events"]
        result.append(zcode)
        result += antigravityBundles(home + "/.gemini/config/hooks.json")
        result += jsonFiles(.copilot, directory("COPILOT_HOME", "/.copilot") + "/hooks")
        result += jsonFiles(.grok, directory("GROK_HOME", "/.grok") + "/hooks")
        let kiro = directory("KIRO_HOME", "/.kiro")
        result += jsonFiles(.kiro, kiro + "/hooks") + jsonFiles(.kiro, kiro + "/agents")
        if let muse = museHooksPath() { result.append(user(.muse, muse)) }
        return result
    }

    private func user(_ host: HookHost, _ path: String) -> SourceDescriptor {
        SourceDescriptor(
            host: host, path: path, tier: "user", scope: "user", scopeRoot: environment.home)
    }

    private func jsonFiles(_ host: HookHost, _ directory: String) -> [SourceDescriptor] {
        entries(directory).filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.map {
            user(host, directory + "/" + $0)
        }
    }

    /// Antigravity groups events into named top-level bundles; each bundle is one event map.
    private func antigravityBundles(_ path: String) -> [SourceDescriptor] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        guard let bundles = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue
        else { return [user(.antigravity, path)] }
        return bundles.keys.sorted().filter { bundles[$0]?.objectValue != nil }.map {
            var source = user(.antigravity, path)
            source.container = [$0]
            return source
        }
    }

    /// Muse loads one extra hooks file named by `managed_hooks_path` in its settings; a relative
    /// value resolves against the settings directory. Unreadable settings are returned as the
    /// source itself so the inventory records an issue instead of silently missing the file.
    private func museHooksPath() -> String? {
        let directory =
            environment.externalValue(for: "XDG_CONFIG_HOME").map { $0 + "/muse" }
            ?? environment.home + "/.config/muse"
        let settings = directory + "/settings.json"
        guard FileManager.default.fileExists(atPath: settings) else { return nil }
        guard let data = FileManager.default.contents(atPath: settings),
            let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return settings }
        guard let path = decoded["managed_hooks_path"]?.stringValue, !path.isEmpty else {
            return nil
        }
        return path.hasPrefix("/") ? path : directory + "/" + path
    }
}
