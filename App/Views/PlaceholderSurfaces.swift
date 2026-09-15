import SwiftUI

/// M3-empty surfaces (§4.3): Pending Changes, Snapshots, and Search exist in
/// the sidebar but render explicit labeled placeholders until their
/// milestones land — never a blank pane or an error (VAL-HEALTH-028).
struct PendingChangesView: View {
    var body: some View {
        SurfacePlaceholder(
            token: "sukiru.pending.empty",
            icon: "list.bullet.rectangle",
            title: "No pending changes",
            explanation: "Repairs arrive as reviewable command batches here in a later milestone."
        )
    }
}

struct SnapshotsView: View {
    var body: some View {
        SurfacePlaceholder(
            token: "sukiru.snapshots.empty",
            icon: "camera.on.rectangle",
            title: "No snapshots yet",
            explanation:
                "Every command batch captures a snapshot before it runs; history appears here."
        )
    }
}

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
