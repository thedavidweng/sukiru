import SwiftUI

extension View {
    /// Pins a surface's own controls (summary, filters, banners) under the
    /// window toolbar. Apply it to the surface's scroll view: the column then
    /// still starts with a scroll view, so the toolbar keeps the system's
    /// scroll-edge treatment instead of falling back to a solid title bar.
    @ViewBuilder
    func surfaceBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(macOS 26.0, *) {
            safeAreaBar(edge: .top, spacing: 0) {
                VStack(spacing: 0, content: bar)
            }
        } else {
            safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0, content: bar)
                    .background(.bar)
            }
        }
    }
}
