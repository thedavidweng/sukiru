import SwiftUI

/// First-frame placeholder for the skeleton milestone. The real surfaces
/// (Library, Health, …) land in later milestones; this view exists so the
/// app presents a normal, focusable window and a stable AX label to drive.
struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Sukiru")
                .font(.largeTitle.weight(.semibold))
            Text("Skill library health check")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityLabel("sukiru.app.placeholder")
        }
        .padding(48)
        .frame(minWidth: 480, minHeight: 320)
    }
}

#Preview {
    PlaceholderView()
}
