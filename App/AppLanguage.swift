import AppKit

/// The app's UI language override. macOS resolves an app's language from
/// `AppleLanguages` in the app's own defaults domain, the same key System
/// Settings › Language & Region › Applications writes, so after a relaunch
/// every surface (SwiftUI, AppKit menus, `String(localized:)`, formatters)
/// follows it. Live switching through `\.locale` would miss all but SwiftUI
/// literals, so the override takes effect on relaunch instead.
enum AppLanguage {
    private static let defaultsKey = "AppleLanguages"

    /// Localizations shipped in the bundle.
    static var available: [String] {
        Bundle.main.localizations.filter { $0 != "Base" }
    }

    /// The bundled localization the user chose, or nil to follow the system.
    static var override: String? {
        get {
            guard let domain = Bundle.main.bundleIdentifier,
                let languages = UserDefaults.standard.persistentDomain(forName: domain)?[
                    defaultsKey] as? [String],
                !languages.isEmpty
            else { return nil }
            return Bundle.preferredLocalizations(from: available, forPreferences: languages).first
        }
        set {
            if let newValue {
                UserDefaults.standard.set([newValue], forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
    }

    /// Whether `selection` differs from the localization this process runs in.
    static func needsRelaunch(for selection: String?) -> Bool {
        let preferences =
            selection.map { [$0] }
            ?? UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[
                defaultsKey] as? [String] ?? []
        let target = Bundle.preferredLocalizations(from: available, forPreferences: preferences)
        return target.first != Bundle.main.preferredLocalizations.first
    }

    /// The language's name in its own language ("English", "中文（简体）").
    static func displayName(_ identifier: String) -> String {
        Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
    }

    @MainActor static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        Task {
            do {
                _ = try await NSWorkspace.shared.openApplication(
                    at: Bundle.main.bundleURL, configuration: configuration)
                NSApp.terminate(nil)
            } catch {
                NSApp.presentError(error)
            }
        }
    }
}
