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
        case "adal", "aider-desk", "amp", "antigravity", "astrbot", "augment", "bob",
            "claude-code", "cline", "codearts-agent", "codebuddy", "codemaker", "codestudio",
            "codex", "command-code", "continue", "cortex", "crush", "cursor", "deepagents",
            "devin", "dexto", "droid", "dsh", "firebender", "forgecode", "fx", "gemini-cli",
            "github-copilot", "goose", "grok", "hermes-agent", "iflow-cli", "jcode", "junie",
            "kilo", "kiro-cli", "lingma", "mcpjam", "minimax-code", "mistral-vibe", "muse", "mux",
            "neovate", "omp", "openclaw", "opencode", "openhands", "pi", "pochi", "qoder",
            "qwen-code", "reasonix", "replit", "roo", "rovodev", "tabnine-cli", "trae", "warp",
            "windsurf", "zcode", "zed", "zencoder":
            return "agent-\(hostID)"
        case "qoder-cn":
            return "agent-qoder"
        case "antigravity-cli":
            return "agent-antigravity"
        case "trae-cn":
            return "agent-trae"
        case "zenflow":
            return "agent-zencoder"
        case "kimi-code-cli":
            return "agent-kimi-cli"
        default:
            return nil
        }
    }
}

/// A host's name with its brand mark, as sidebar and Settings rows show it.
struct HostLabel: View {
    let name: String
    let agentID: String

    var body: some View {
        Label {
            Text(verbatim: name)
        } icon: {
            // Keeps names aligned for agents without artwork.
            AgentLogo(hostID: agentID, size: 16)
                .frame(width: 16, height: 16)
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
