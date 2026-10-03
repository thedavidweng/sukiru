import Foundation

extension PluginLifecycleCapture {
    func baseRoots(host: PluginHost) -> [String] {
        let home = environment.home
        switch host {
        case .claude:
            let config =
                environment.externalValue(for: "CLAUDE_CONFIG_DIR")
                ?? HostPathResolver.join(home, ".claude")
            var roots = [config]
            if let cache = environment.externalValue(for: "CLAUDE_CODE_PLUGIN_CACHE_DIR") {
                roots.append(cache)
            }
            roots += environment.projectRoots.map { HostPathResolver.join($0, ".claude") }
            return roots
        case .codex:
            var roots = [
                environment.externalValue(for: "CODEX_HOME")
                    ?? HostPathResolver.join(home, ".codex"),
                HostPathResolver.join(home, ".agents/plugins")
            ]
            roots += environment.projectRoots.flatMap {
                [HostPathResolver.join($0, ".codex"), HostPathResolver.join($0, ".agents/plugins")]
            }
            return roots
        case .opencode: return openCodeRoots()
        }
    }

    private func openCodeRoots() -> [String] {
        let home = environment.home
        let config =
            environment.externalValue(for: "OPENCODE_CONFIG_DIR")
            ?? HostPathResolver.join(
                environment.xdgConfigHome ?? environment.externalValue(for: "XDG_CONFIG_HOME")
                    ?? HostPathResolver.join(home, ".config"), "opencode")
        let cache =
            environment.externalValue(for: "XDG_CACHE_HOME")
            ?? HostPathResolver.join(home, ".cache")
        let state =
            environment.xdgStateHome ?? environment.externalValue(for: "XDG_STATE_HOME")
            ?? HostPathResolver.join(home, ".local/state")
        let data =
            environment.externalValue(for: "XDG_DATA_HOME")
            ?? HostPathResolver.join(home, ".local/share")
        let temporary = environment.homeIsOverridden ? home : temporaryRoot()
        var roots = [
            config, HostPathResolver.join(cache, "opencode"),
            HostPathResolver.join(state, "opencode"),
            HostPathResolver.join(data, "opencode"), HostPathResolver.join(temporary, "opencode")
        ]
        if let direct = environment.externalValue(for: "OPENCODE_CONFIG") {
            roots.append(direct)
        }
        roots += environment.projectRoots.flatMap {
            [
                HostPathResolver.join($0, "opencode.json"),
                HostPathResolver.join($0, "opencode.jsonc"),
                HostPathResolver.join($0, ".opencode")
            ]
        }
        return roots
    }

    private func temporaryRoot() -> String {
        for key in ["TMPDIR", "TMP", "TEMP"] {
            if let value = environment.externalValue(for: key) { return value }
        }
        return "/tmp"
    }

    private func npmEnvironmentRoots(_ process: [String: String]) -> [String] {
        let options = ["npm_config_cache", "npm_config_logs_dir", "npm_config_logs-dir"]
        return process.filter { options.contains($0.key.lowercased()) }.map(\.value)
    }

    func npmRoots() throws -> [String] {
        var roots = [HostPathResolver.join(environment.home, ".npm")]
        let process = ProcessInfo.processInfo.environment
        if !environment.homeIsOverridden { roots += npmEnvironmentRoots(process) }
        var configs = [HostPathResolver.join(environment.home, ".npmrc")]
        configs += environment.projectRoots.map { HostPathResolver.join($0, ".npmrc") }
        if !environment.homeIsOverridden {
            for key in [
                "npm_config_userconfig", "NPM_CONFIG_USERCONFIG", "npm_config_globalconfig",
                "NPM_CONFIG_GLOBALCONFIG"
            ] {
                if let config = process[key] { configs.append(config) }
            }
            if let prefix = process["npm_config_prefix"] ?? process["NPM_CONFIG_PREFIX"] {
                configs.append(HostPathResolver.join(prefix, "etc/npmrc"))
            }
            if let npm = CLIExecutor(environment: environment).resolveExecutable("npm") {
                configs.append(
                    npm.deletingLastPathComponent().deletingLastPathComponent()
                        .appendingPathComponent("etc/npmrc").path)
            }
        }
        for path in configs where FileManager.default.fileExists(atPath: path) {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if parts.count == 2 && ["cache", "logs-dir"].contains(parts[0].lowercased()) {
                    let value = parts[1].replacingOccurrences(of: "${HOME}", with: environment.home)
                    guard value.hasPrefix("/"), !value.contains("${") else {
                        throw PluginLifecycleError(
                            message: "Cannot resolve effective npm cache/log directory in " + path)
                    }
                    roots.append(value)
                }
            }
        }
        return roots
    }

}
