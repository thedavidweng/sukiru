import SwiftUI

/// One action in a column's toolbar. Every toolbar control in the app is declared
/// through this type, never as a bare `ToolbarItem`, so each control gets its own
/// system glass. Adjacent items with no spacer merge into a shared group, whose
/// controls render translucent until hovered; the fixed spacer after each action
/// keeps them apart. `ToolbarSpacer` needs macOS 26, so older systems skip it.
struct ColumnAction<Content: View>: ToolbarContent {
    private let content: Content

    init(@ViewBuilder _ content: () -> Content) {
        self.content = content()
    }

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        ToolbarItem {
            content
        }
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
        }
    }
}
