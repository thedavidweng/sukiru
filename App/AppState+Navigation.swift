extension AppState {
    enum LibraryContent: String, CaseIterable {
        case skills
        case plugins
    }
    /// Sidebar surfaces. Settings lives in the standard macOS Settings scene.
    enum Surface: String, CaseIterable, Identifiable, Hashable {
        case library
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
