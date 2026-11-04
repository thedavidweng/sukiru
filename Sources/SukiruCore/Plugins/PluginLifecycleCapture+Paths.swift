import Foundation

extension PluginLifecycleCapture {
    /// Configuration and registry files each host's plugin commands write. Plugin payloads,
    /// caches, marketplace checkouts and persistent data are excluded: see
    /// `PluginLifecycleCapture.roots`.
    func baseRoots(host: PluginHost) -> [String] {
        let home = environment.home
        switch host {
        case .claude:
            let config =
                environment.externalValue(for: "CLAUDE_CONFIG_DIR")
                ?? HostPathResolver.join(home, ".claude")
            return Self.claudeSettings(in: config) + [HostPathResolver.join(home, ".claude.json")]
                + environment.projectRoots.flatMap {
                    Self.claudeSettings(in: HostPathResolver.join($0, ".claude"))
                }
        case .codex:
            return [
                HostPathResolver.join(
                    environment.externalValue(for: "CODEX_HOME")
                        ?? HostPathResolver.join(home, ".codex"), "config.toml")
            ] + environment.projectRoots.map {
                HostPathResolver.join($0, ".codex/config.toml")
            }
        case .opencode: return openCodeRoots()
        case .cursor:
            // Cursor's marketplace registrations are not in a file Sukiru can locate, so
            // nothing is captured for them; its payload tree under ~/.cursor/plugins is excluded.
            return []
        case .antigravity:
            let config = HostPathResolver.join(home, ".gemini/config")
            return [
                HostPathResolver.join(config, "config.json"),
                HostPathResolver.join(config, "import_manifest.json"),
                HostPathResolver.join(config, "plugins.json")
            ] + environment.projectRoots.flatMap {
                PluginInventoryReader(environment: environment).antigravityProjectLocations($0)
                    .map { HostPathResolver.join($0, "plugins.json") }
            }
        case .hermes:
            return [HostPathResolver.join(home, ".hermes/config.yaml")]
        case .droid:
            return [HostPathResolver.join(home, ".factory/settings.json")]
                + environment.projectRoots.map { HostPathResolver.join($0, ".factory/settings.json") }
        }
    }

    /// Plugin commands write enablement and marketplace declarations here; the rest of a
    /// Claude config directory is session history the commands never touch.
    static func claudeSettings(in directory: String) -> [String] {
        ["settings.json", "settings.local.json"].map { HostPathResolver.join(directory, $0) }
    }

    /// OpenCode configuration only. Its package cache, state and data are payloads.
    private func openCodeRoots() -> [String] {
        let home = environment.home
        let config =
            environment.externalValue(for: "OPENCODE_CONFIG_DIR")
            ?? HostPathResolver.join(
                environment.xdgConfigHome ?? environment.externalValue(for: "XDG_CONFIG_HOME")
                    ?? HostPathResolver.join(home, ".config"), "opencode")
        var roots = [config]
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
                HostPathResolver.join($0, "cli.jsonc")
            ]
        }
        return roots
    }
}
