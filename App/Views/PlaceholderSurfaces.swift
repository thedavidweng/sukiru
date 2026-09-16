import SwiftUI

/// M3-empty surfaces (§4.3): Search exists in the sidebar but renders an
/// explicit labeled placeholder until its milestone lands — never a blank
/// pane or an error (VAL-HEALTH-028). Pending Changes and Snapshots got
/// their real M4 surfaces (PendingChangesView.swift / SnapshotsView.swift);
/// their empty states render through the same placeholder.
struct SearchView: View {
    var body: some View {
        SurfacePlaceholder(
            token: "sukiru.search.idle",
            icon: "magnifyingglass",
            title: "Search is idle",
            explanation:
                "Skill search arrives in a later milestone. Enter a query then to find new skills."
        )
    }
}

/// Shared placeholder: token carrier + icon + title + explanatory text.
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
