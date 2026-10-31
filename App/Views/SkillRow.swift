import SukiruCore
import SwiftUI

/// One skill row, laid out like a Mail message: name and the agents that read
/// it on the first line, description and installer on the second. A trailing
/// marker after the agents carries the only alarm color, and only for findings
/// that ask for a fix.
///
/// The row holds only values, so SwiftUI skips rows whose model did not
/// change instead of re-rendering every visible row on each app-state update.
struct SkillRow: View, Equatable {
    struct Model: Equatable {
        let name: String
        let token: String
        let packageName: String?
        let packageHelp: String?
        let hosts: [LibraryHostsSection.HostEntry]
        let needsAttention: Bool
        let summary: String
        let updateAvailable: Bool
        let ambiguous: Bool
        let isInternal: Bool
        let ownership: Ownership
    }

    let model: Model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            AXToken(token: "sukiru.library.skillRow.\(model.token)")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 8) {
                    Text(model.name)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if let package = model.packageName {
                        Text(package)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(model.packageHelp ?? package)
                    }
                    Spacer(minLength: 0)
                    AgentIconStrip(hosts: model.hosts)
                    if model.needsAttention {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .imageScale(.small)
                            .symbolRenderingMode(.multicolor)
                            .help("Needs attention")
                            .accessibilityLabel("Needs attention")
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.summary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    status
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var status: some View {
        HStack(spacing: 6) {
            if model.updateAvailable {
                Text("Update Available")
            }
            if model.ambiguous {
                Text("Ambiguous")
            }
            if model.isInternal {
                HStack(spacing: 0) {
                    AXToken(token: "sukiru.library.badge.internal.\(AXTokens.skill(model.name))")
                    Text("Internal")
                }
            }
            HStack(spacing: 0) {
                AXToken(token: "sukiru.library.badge.ownership.\(AXTokens.skill(model.name))")
                Text(model.ownership.title)
            }
        }
    }
}

extension AppState {
    func rowModel(for skill: Skill) -> SkillRow.Model {
        let package = skill.provenance.pnpm?.first
        return SkillRow.Model(
            name: skill.name,
            token: AXTokens.skill(skill.packageQualifiedName ?? skill.name),
            packageName: package?.packageName,
            packageHelp: skill.packageQualifiedName,
            hosts: hostEntries(for: skill).filter(\.installed),
            needsAttention: needsAttention(skill),
            summary: skillDescriptions[skill.selfID] ?? "",
            updateAvailable: githubUpdate(for: skill) != nil,
            ambiguous: skill.ambiguous,
            isInternal: skill.placements.contains(where: \.internal),
            ownership: skill.ownership)
    }
}

extension Ownership {
    var title: LocalizedStringResource {
        switch self {
        case .vercel: "Vercel"
        case .github: "GitHub"
        case .pnpm: "Managed by pnpm"
        case .doubleBooked: "Double-booked"
        case .ownerless: "Ownerless"
        case .agent: "Agent-managed"
        }
    }
}
