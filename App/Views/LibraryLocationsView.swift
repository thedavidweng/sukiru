import SukiruCore
import SwiftUI

struct LibraryLocationsView: View {
    @EnvironmentObject private var state: AppState

    let skill: Skill

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LibraryHostsSection(
                    skill: skill, report: state.report, environment: state.environment,
                    projectRoot: state.projectRoot(of: skill))
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Placements")
                        .font(.headline)
                    ForEach(skill.placements, id: \.path) { placement in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(placement.path)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                            Text(kind(placement))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
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
