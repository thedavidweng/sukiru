import SwiftUI

/// A list group's header: its scope or folder name, with the item count trailing.
/// Every list that groups items uses it, so a header reads the same on each surface.
struct ListSectionHeader<Title: View>: View {
    let title: Title
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            title
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(count, format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
