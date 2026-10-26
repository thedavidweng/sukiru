import Foundation

enum PluginActionTitle {
    static func title(_ action: String) -> String {
        titles[action]!
    }

    static func symbol(_ action: String) -> String {
        switch action {
        case "update": "arrow.down.circle"
        case "check": "arrow.triangle.2.circlepath"
        case "replace": "arrow.left.arrow.right"
        case "list": "list.bullet"
        case "disable-local": "pause.circle"
        case "remove": "trash"
        case "import": "square.and.arrow.down"
        case "validate": "checkmark.seal"
        case "link": "link"
        default: "gearshape"
        }
    }

    private static let titles = [
        "install": String(localized: "Install Plugin"),
        "replace": String(localized: "Replace Plugin Version"),
        "enable": String(localized: "Enable Plugin"),
        "disable": String(localized: "Disable Plugin"),
        "disable-local": String(localized: "Disable Local Loading"),
        "update": String(localized: "Update Plugin"),
        "remove": String(localized: "Remove Plugin"),
        "check": String(localized: "Check Plugin Updates"),
        "list": String(localized: "Inspect Host Plugins"),
        "import": String(localized: "Import Plugins"),
        "validate": String(localized: "Validate Plugin"),
        "link": String(localized: "Generate Marketplace Link"),
        "marketplace-add": String(localized: "Add Marketplace"),
        "marketplace-refresh": String(localized: "Refresh Marketplace"),
        "marketplace-remove": String(localized: "Remove Marketplace")
    ]
}
