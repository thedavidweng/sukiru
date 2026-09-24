import SwiftUI

/// Shared empty state for surfaces without content.
struct SurfacePlaceholder: View {
    let token: String
    let icon: String
    let title: LocalizedStringKey
    let explanation: LocalizedStringKey

    var body: some View {
        ContentUnavailableView {
            HStack(spacing: 0) {
                AXToken(token: token)
                Label(title, systemImage: icon)
            }
        } description: {
            Text(explanation)
        }
    }
}
