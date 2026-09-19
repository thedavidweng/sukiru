import SwiftUI

/// Shared empty state for surfaces without content.
struct SurfacePlaceholder: View {
    let token: String
    let icon: String
    let title: LocalizedStringKey
    let explanation: LocalizedStringKey

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                AXToken(token: token)
                Text(title)
                    .font(.title3.weight(.semibold))
            }
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
