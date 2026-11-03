import Foundation

extension PluginLifecycleCapture {
    func baseRoots(host: PluginHost) -> [String] {
        let home = environment.home
        switch host {
        case .claude:
            let config =
                environment.externalValue(for: "CLAUDE_CONFIG_DIR")
                ?? HostPathResolver.join(home, ".claude")
            var roots =
                Self.claudeSettings(in: config) + [
                    HostPathResolver.join(config, "plugins"),
                    HostPathResolver.join(home, ".claude.json")
                ]
            if let cache = environment.externalValue(for: "CLAUDE_CODE_PLUGIN_CACHE_DIR") {
                roots.append(cache)
            }
            roots += environment.projectRoots.flatMap {
                Self.claudeSettings(in: HostPathResolver.join($0, ".claude"))
            }
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
        case .cursor: return [HostPathResolver.join(home, ".cursor/plugins")]
        case .antigravity:
            return [
                HostPathResolver.join(home, ".gemini/config"),
                HostPathResolver.join(home, ".gemini/antigravity-cli"),
                HostPathResolver.join(home, ".gemini/antigravity")
            ]
                + environment.projectRoots.flatMap {
                    PluginInventoryReader(environment: environment).antigravityProjectLocations($0)
                }
        case .droid:
            return [
                HostPathResolver.join(home, ".factory/plugins"),
                HostPathResolver.join(home, ".factory/settings.json")
            ] + environment.projectRoots.map { HostPathResolver.join($0, ".factory/settings.json") }
        }
    }

    /// Plugin commands write enablement and marketplace declarations here; the rest of a
    /// Claude config directory is session history the commands never touch.
    static func claudeSettings(in directory: String) -> [String] {
        ["settings.json", "settings.local.json"].map { HostPathResolver.join(directory, $0) }
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
        roots += ([home] + environment.projectRoots).flatMap {
            [
                HostPathResolver.join($0, "opencode.json"),
                HostPathResolver.join($0, "opencode.jsonc"),
                HostPathResolver.join($0, "tui.json"),
                HostPathResolver.join($0, "tui.jsonc"),
                HostPathResolver.join($0, "cli.json"),
                HostPathResolver.join($0, "cli.jsonc"),
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
}
