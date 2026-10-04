import Foundation
import SukiruCore

extension PluginHost {
    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
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
        case .opencode:
            ["install", "replace", "update", "check", "list", "remove"]
        }
    }

    var hasMarketplaces: Bool { self != .opencode }
}

extension PluginInstallation {
    var displayName: String {
        switch host {
        case .claude, .codex:
            String(identifier.prefix { $0 != "@" })
        case .opencode:
            identifier.hasPrefix("./") ? String(identifier.dropFirst(2)) : identifier
        }
    }

    var sourceTitle: String {
        source.hasPrefix("/") || source.hasPrefix("./") ? String(localized: "Local Plugin") : source
    }

    /// Per-installation operations. Codex updates arrive only through a
    /// whole-marketplace refresh; OpenCode's discovered local files have no
    /// package lifecycle, and removal previews explain that limit.
    var actions: [String] {
        switch host {
        case .claude:
            (enablement == .enabled ? [] : ["enable"])
                + (enablement == .disabled ? [] : ["disable"]) + ["update", "remove"]
        case .codex:
            ["remove"]
        case .opencode:
            installationStatus == "discovered"
                ? ["disable-local", "remove"] : ["update", "check", "replace", "remove"]
        }
    }

    var localizedInstallationStatus: String {
        switch installationStatus {
        case "installed": String(localized: "Installed payload")
        case "configured": String(localized: "Configured reference")
        case "discovered": String(localized: "Discovered local file")
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
