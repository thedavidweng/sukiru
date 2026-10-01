import SukiruCore
import SwiftUI

/// One skill row, laid out like a Mail message: name and the agents that read
/// it on the first line, description and installer on the second. The leading
/// gutter carries the only alarm color, and only for findings that ask for a
/// fix.
struct SkillRow: View {
    @EnvironmentObject private var state: AppState
    let skill: Skill

    var body: some View {
        let hosts = LibraryHostsSection(
            skill: skill, report: state.report, environment: state.environment,
            projectRoot: state.projectRoot(of: skill)
        )
        .hostEntries().filter(\.installed)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            AXToken(token: "sukiru.library.skillRow.\(AXTokens.skill(skill.name))")
            attentionMarker
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 8) {
                    Text(skill.name)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    AgentIconStrip(hosts: hosts)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(state.skillDescriptions[skill.selfID] ?? "")
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

    @ViewBuilder
    private var attentionMarker: some View {
        let symbol = Image(systemName: "exclamationmark.triangle.fill")
            .imageScale(.small)
            .frame(width: 14)
        if state.needsAttention(skill) {
            symbol
                .symbolRenderingMode(.multicolor)
                .help("Needs attention")
                .accessibilityLabel("Needs attention")
        } else {
            symbol
                .hidden()
                .accessibilityHidden(true)
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            if skill.ambiguous {
                Text("Ambiguous")
            }
            if skill.placements.contains(where: \.internal) {
                HStack(spacing: 0) {
                    AXToken(token: "sukiru.library.badge.internal.\(AXTokens.skill(skill.name))")
                    Text("Internal")
                }
            }
            HStack(spacing: 0) {
                AXToken(token: "sukiru.library.badge.ownership.\(AXTokens.skill(skill.name))")
                Text(skill.ownership.title)
            }
        }
    }
}

extension Ownership {
    var title: LocalizedStringResource {
        switch self {
        case .vercel: "Vercel"
        case .github: "GitHub"
        case .doubleBooked: "Double-booked"
        case .ownerless: "Ownerless"
        case .agent: "Agent-managed"
        }
    }
}
