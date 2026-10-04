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
