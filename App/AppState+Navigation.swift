extension AppState {
    /// Sidebar surfaces. Settings lives in the standard macOS Settings scene.
    enum Surface: String, CaseIterable, Identifiable, Hashable {
        case library
        /// One host's plugins (`pluginHost`); each host's plugin system is its own.
        case plugins
        case hooks
        case health
        case pending
        case snapshots
        case search

        var id: String { rawValue }
    }

    enum LibraryScope: Hashable {
        case all
        case user
        case project(String)
    }

    var isProjectScopeSelected: Bool {
        if case .project = libraryScope { return true }
        return false
    }
}
