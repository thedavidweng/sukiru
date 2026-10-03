import Foundation
import SukiruCore

extension PluginInstallation {
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
