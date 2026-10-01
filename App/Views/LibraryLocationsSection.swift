import SukiruCore
import SwiftUI

/// Every on-disk placement of a skill, each one revealable in Finder.
struct LibraryLocationsSection: View {
    @EnvironmentObject private var state: AppState

    let skill: Skill

    var body: some View {
        Section("Locations") {
            ForEach(skill.placements, id: \.path) { placement in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(placement.path)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(placement.path)
                        Text(kind(placement))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        state.revealInFinder([placement.path])
                    } label: {
                        Label("Show in Finder", systemImage: "arrow.forward.circle.fill")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(placement.kind == .brokenSymlink)
                    .help("Show in Finder")
                }
            }
        }
    }

    private func kind(_ placement: Placement) -> LocalizedStringKey {
        if placement.internal { return "Internal" }
        switch placement.kind {
        case .directory: return "Directory"
        case .symlink: return "Symbolic link"
        case .brokenSymlink: return "Broken symbolic link"
        }
    }
}
