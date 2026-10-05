import Foundation
import SukiruCore
import SwiftUI

extension PluginHost {
    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .cursor: "Cursor"
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
            ["install", "remove", "marketplace-add", "marketplace-refresh", "marketplace-remove"]
        case .cursor:
            ["install", "marketplace-add", "marketplace-refresh", "marketplace-remove"]
        case .opencode:
            ["install", "replace", "update", "check", "list", "remove"]
        }
    }

    var hasMarketplaces: Bool { self != .opencode }
}

extension PluginInstallation {
    var displayName: String {
        switch host {
        case .claude, .codex, .cursor:
            String(identifier.prefix { $0 != "@" })
        case .opencode:
            identifier.hasPrefix("./") ? String(identifier.dropFirst(2)) : identifier
        }
    }

    var sourceTitle: String {
        source.hasPrefix("/") || source.hasPrefix("./") ? String(localized: "Local Plugin") : source
    }

    /// Per-installation operations. Claude's managed installations accept
    /// only update; Codex updates arrive only through a whole-marketplace
    /// refresh; OpenCode's discovered local files have no package lifecycle,
    /// so a package removal of the same name is never offered for them.
    var actions: [String] {
        switch host {
        case .claude:
            scope == "managed"
                ? ["update"]
                : (enablement == .enabled ? [] : ["enable"])
                    + (enablement == .disabled ? [] : ["disable"]) + ["update", "remove"]
        case .codex:
            ["remove"]
        case .cursor:
            installationStatus == "discovered" ? ["disable-local"] : []
        case .opencode:
            installationStatus == "discovered"
                ? ["disable-local"] : ["update", "check", "replace", "remove"]
        }
    }

    /// Why the enabled switch is dimmed for this installation.
    var fixedEnablementReason: LocalizedStringKey {
        switch host {
        case .codex:
            "Codex has no command to enable or disable one plugin; its feature flags are not plugin enablement"
        case .claude where scope == "managed":
            "Managed settings control this plugin; change it where your organization manages Claude Code"
        default:
            "This host has no command to change whether this plugin is enabled"
        }
    }

    /// Why the toolbar's Update is dimmed for this installation.
    var noUpdateReason: LocalizedStringKey {
        switch host {
        case .codex:
            "Codex updates plugins only by refreshing their whole marketplace"
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
            if host == .cursor {
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
