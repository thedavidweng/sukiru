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
        case "adal", "aider-desk", "amp", "antigravity", "augment", "bob", "claude-code", "cline",
            "codearts-agent", "codebuddy", "codemaker", "codestudio", "codex", "command-code",
            "continue", "cortex", "crush", "cursor", "deepagents", "devin", "dexto", "droid",
            "firebender", "forgecode", "gemini-cli", "github-copilot", "goose", "hermes-agent",
            "iflow-cli", "junie", "kilo", "kiro-cli", "mcpjam", "mistral-vibe", "mux", "neovate",
            "openclaw",
            "opencode", "openhands", "pi", "pochi", "qoder", "qwen-code", "replit", "roo",
            "rovodev", "tabnine-cli", "trae", "warp", "windsurf", "zed", "zencoder":
            return "agent-\(hostID)"
        case "qoder-cn":
            return "agent-qoder"
        case "trae-cn":
            return "agent-trae"
        case "kimi-code-cli":
            return "agent-kimi-cli"
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
