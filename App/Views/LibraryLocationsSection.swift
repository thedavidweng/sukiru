import SukiruCore
import SwiftUI

/// Every on-disk placement of a skill, each one revealable in Finder.
struct LibraryLocationsSection: View {
    @EnvironmentObject private var state: AppState

    let skill: Skill

    var body: some View {
        Section {
            locations
        } header: {
            Text("Locations")
        } footer: {
            if skill.ownership != .agent {
                modeSwitch
            }
        }
    }

    /// Link ↔ copy switch: links share one folder so every agent sees the
    /// same version; copies let each agent keep its own.
    @ViewBuilder private var modeSwitch: some View {
        let copies = skill.placements.filter { $0.kind == .directory }.count
        let links = skill.placements.filter { $0.kind == .symlink }.count
        if copies > 1 || links > 0 {
            HStack {
                Text("library.mode \(copies) \(links)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if copies > 1 {
                    Button("Use Links") {
                        state.switchMode(of: skill, to: .link)
                    }
                    .help("Replace the agent copies with links to one shared copy")
                }
                if links > 0 {
                    Button("Use Copies") {
                        state.switchMode(of: skill, to: .copy)
                    }
                    .help("Replace the links with standalone copies")
                }
            }
            .disabled(state.batchMutationInFlight)
        }
    }

    private var locations: some View {
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

    private func kind(_ placement: Placement) -> LocalizedStringKey {
        if placement.internal { return "Internal" }
        switch placement.kind {
        case .directory: return "Directory"
        case .symlink: return "Symbolic link"
        case .brokenSymlink: return "Broken symbolic link"
        }
    }
}
