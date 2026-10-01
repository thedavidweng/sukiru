import SwiftUI

/// Brand marks identify the agent workspaces that actually contain a skill.
/// Hosts without supplied artwork remain text-only; a generic document glyph
/// would imply every skill has the same origin.
struct AgentLogo: View {
    let hostID: String
    var size: CGFloat = 18

    var body: some View {
        if let assetName = Self.assetName(for: hostID) {
            Image(assetName)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    static func assetName(for hostID: String) -> String? {
        switch hostID {
        case "amp", "antigravity", "augment", "claude-code", "cline", "codex", "cursor",
            "droid", "gemini-cli", "github-copilot", "hermes-agent", "kilo", "kimi-cli",
            "kiro-cli", "mistral-vibe", "openclaw", "opencode", "pi", "roo", "trae",
            "warp", "windsurf", "zed":
            return "agent-\(hostID)"
        case "trae-cn":
            return "agent-trae"
        default:
            return nil
        }
    }
}

struct AgentIconStrip: View {
    let hosts: [LibraryHostsSection.HostEntry]
    private let limit = 3

    private var illustratedHosts: [LibraryHostsSection.HostEntry] {
        hosts.filter { AgentLogo.assetName(for: $0.hostID) != nil }
    }

    var body: some View {
        let shown = illustratedHosts.prefix(limit)
        HStack(spacing: 5) {
            ForEach(shown, id: \.workspaceID) { host in
                AgentLogo(hostID: host.hostID, size: 13)
            }
            if hosts.count > shown.count {
                Text(verbatim: "+\(hosts.count - shown.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hosts.map(\.displayName).formatted(.list(type: .and)))
        .help(hosts.map(\.displayName).formatted(.list(type: .and)))
    }
}
