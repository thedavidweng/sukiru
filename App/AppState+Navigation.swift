extension AppState {
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
}
