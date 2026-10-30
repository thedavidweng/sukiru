import Foundation
import SukiruCore
import SwiftUI

extension HookHost {
    var displayName: String {
        if let plugin = PluginHost(rawValue: rawValue) { return plugin.displayName }
        switch self {
        case .openclaude: return "OpenClaude"
        case .muse: return "Muse"
        case .jcode: return "jcode"
        case .dsh: return "DeepSeek (dsh)"
        default: return HostTable.host(id: agentID)?.displayName ?? rawValue
        }
    }
}

extension ExtensionHost {
    var displayName: String {
        if let plugin = PluginHost(rawValue: rawValue) { return plugin.displayName }
        if let hook = HookHost(rawValue: rawValue) { return hook.displayName }
        switch self {
        case .omp: return "oh-my-pi"
        default: return HostTable.host(id: agentID)?.displayName ?? rawValue
        }
    }

    /// Hosts listed under Extensions: auto-loaded files, packages, and plugins.
    static let addOnHosts = allCases.filter { $0.categories.contains { $0 != .mcpServer } }
    static let mcpHosts = allCases.filter { $0.categories.contains(.mcpServer) }
}

extension ExtensionCategory {
    var title: LocalizedStringKey {
        switch self {
        case .autoloaded: "Extensions"
        case .package: "Packages"
        case .plugin: "Plugins"
        case .mcpServer: "MCP Servers"
        }
    }
}

extension PluginHost {
    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .cursor: "Cursor"
        case .antigravity: "Antigravity"
        }
    }

    var agentID: String { self == .claude ? "claude-code" : rawValue }

    /// The operation families this host's own plugin interface offers.
    /// Version and scope limits still surface in the planner's preview.
    var operations: [String] {
        switch self {
        case .claude:
            [
                "install", "enable", "disable", "update", "remove", "marketplace-add",
                "marketplace-refresh", "marketplace-remove"
            ]
        case .codex:
            [
                "install", "enable", "disable", "remove", "marketplace-add",
                "marketplace-refresh", "marketplace-remove"
            ]
        case .cursor:
            ["install", "marketplace-add", "marketplace-refresh", "marketplace-remove"]
        case .opencode:
            ["install", "replace", "update", "check", "list", "remove"]
        case .antigravity:
            ["install", "enable", "disable", "remove", "list", "import", "validate", "link"]
        }
    }

    var hasMarketplaces: Bool { self != .opencode }
}

extension PluginInstallation {
    var displayName: String {
        switch host {
        case .claude, .codex, .cursor:
            String(identifier.prefix { $0 != "@" })
        case .antigravity:
            name ?? identifier
        case .opencode:
            identifier.hasPrefix("./") ? String(identifier.dropFirst(2)) : identifier
        }
    }

    var sourceTitle: String {
        source.hasPrefix("/") || source.hasPrefix("./") ? String(localized: "Local Plugin") : source
    }

    /// Per-installation operations. Claude's managed installations accept
    /// only update; Codex updates arrive only through a whole-marketplace
    /// refresh, and its enablement is the plugin's documented `enabled` key
    /// in config.toml; OpenCode's discovered local files have no package
    /// lifecycle, so a package removal of the same name is never offered.
    var actions: [String] {
        switch host {
        case .claude:
            scope == "managed" ? ["update"] : enablementActions + ["update", "remove"]
        case .codex:
            enablementActions + ["remove"]
        case .antigravity:
            enablementActions + ["validate"]
                + (path == HostPathResolver.join(scopeRoot, ".gemini/config/plugins/" + identifier)
                    && scope == "user" ? ["remove"] : [])
        case .cursor:
            installationStatus == "discovered" ? ["disable-local"] : []
        case .opencode:
            installationStatus == "discovered"
                ? ["disable-local"] : ["update", "check", "replace", "remove"]
        }
    }

    private var enablementActions: [String] {
        (enablement == .enabled ? [] : ["enable"]) + (enablement == .disabled ? [] : ["disable"])
    }

    /// Why the enabled switch is dimmed for this installation.
    var fixedEnablementReason: LocalizedStringKey {
        switch host {
        case .codex:
            "Codex reads this plugin's enablement from the enabled key in config.toml; edit it there"
        case .claude where scope == "managed":
            "Managed settings control this plugin; change it where your organization manages Claude Code"
        case .cursor:
            """
            Cursor has no command to enable or disable one plugin, \
            and Sukiru does not read its state store; manage it in Cursor
            """
        default:
            "This host has no command to change whether this plugin is enabled"
        }
    }

    /// The short row text shown where the enabled switch would be.
    var enablementStatus: LocalizedStringKey {
        host == .cursor && installationStatus == "cached"
            ? "Cached · Manage in Cursor" : "Enablement unknown"
    }

    /// Why the toolbar's Update is dimmed for this installation.
    var noUpdateReason: LocalizedStringKey {
        switch host {
        case .codex:
            "Codex updates plugins only by refreshing their whole marketplace"
        case .antigravity:
            "Antigravity manages automatic updates in Customizations; no native update command is available"
        case .cursor:
            "Cursor updates plugins in Customize or the Agent /plugin flow"
        case .opencode:
            "Local plugin files have no package update"
        case .claude:
            "This plugin has no update the host can run here"
        }
    }

    var localizedInstallationStatus: String {
        switch installationStatus {
        case "installed": String(localized: "Installed payload")
        case "configured": String(localized: "Configured reference")
        case "discovered":
            if host == .cursor || host == .antigravity {
                String(localized: "Discovered local plugin")
            } else {
                String(localized: "Discovered local file")
            }
        case "cached": String(localized: "Cached payload; installation unknown")
        default: String(localized: "Recorded by host")
        }
    }
}

extension PluginEnablement {
    var localizedTitle: String {
        switch self {
        case .enabled: String(localized: "Enabled")
        case .disabled: String(localized: "Disabled")
        case .unknown: String(localized: "Unknown")
        }
    }
}

extension PluginComponent {
    var localizedKind: String {
        switch kind {
        case "skills": String(localized: "Skills")
        case "commands": String(localized: "Commands")
        case "agents": String(localized: "Agents")
        case "rules": String(localized: "Rules")
        case "hooks": String(localized: "Hooks")
        case "mcpServers": String(localized: "MCP Servers")
        case "lspServers": String(localized: "LSP Servers")
        case "sidecars": String(localized: "Sidecars")
        case "contextProviders": String(localized: "Context Providers")
        case "variables": String(localized: "Variables")
        case "local": String(localized: "Local Plugin")
        default: kind
        }
    }
}
