/// What shows an agent is installed: its app, command, or editor extension.
/// A config folder outlives an uninstall, so for the agents listed here it
/// does not mean installed on its own. Agents missing from this table are
/// judged by their config folder alone. Every entry comes from the official
/// source listed under "Installed-agent detection" in
/// docs/agent-interface-sources.md; update both together.
enum AgentLauncher {
    struct Probe {
        var commands: [String] = []
        var apps: [String] = []
        /// VS Code-family extension ids, matched as `<id>-<version>` folders.
        var extensions: [String] = []
    }

    /// Editors whose `extensions` folder holds VS Code-family extensions.
    static let editorHomes = [
        ".vscode", ".vscode-insiders", ".cursor", ".windsurf", ".trae", ".kiro"
    ]

    static let probes: [String: Probe] = [
        "adal": Probe(commands: ["adal"]),
        "amp": Probe(commands: ["amp"]),
        "antigravity": Probe(apps: ["Antigravity"]),
        "antigravity-cli": Probe(commands: ["agy"]),
        "augment": Probe(commands: ["auggie"], extensions: ["augment.vscode-augment"]),
        "autohand-code": Probe(commands: ["autohand"]),
        "bob": Probe(commands: ["bob"]),
        "claude-code": Probe(commands: ["claude"], apps: ["Claude"]),
        "cline": Probe(commands: ["cline"], extensions: ["saoudrizwan.claude-dev"]),
        "codebuddy": Probe(commands: ["codebuddy"], apps: ["CodeBuddy"]),
        "codex": Probe(commands: ["codex"], apps: ["Codex"]),
        "command-code": Probe(commands: ["cmd", "commandcode", "command-code"]),
        "continue": Probe(commands: ["cn"], extensions: ["continue.continue"]),
        "cortex": Probe(commands: ["cortex"]),
        "crush": Probe(commands: ["crush"]),
        "cursor": Probe(commands: ["agent"], apps: ["Cursor"]),
        "deepagents": Probe(commands: ["dcode"]),
        "devin": Probe(commands: ["devin"]),
        "dexto": Probe(commands: ["dexto"]),
        "droid": Probe(commands: ["droid"]),
        "dsh": Probe(commands: ["dsh"]),
        "forgecode": Probe(commands: ["forge"]),
        "fx": Probe(commands: ["fx"]),
        "gemini-cli": Probe(commands: ["gemini"]),
        "github-copilot": Probe(commands: ["copilot"], extensions: ["github.copilot-chat"]),
        "goose": Probe(commands: ["goose"], apps: ["Goose"]),
        "grok": Probe(commands: ["grok"]),
        "hermes-agent": Probe(commands: ["hermes"]),
        "iflow-cli": Probe(commands: ["iflow"]),
        "kilo": Probe(commands: ["kilo"], extensions: ["kilocode.kilo-code"]),
        "kimi-code-cli": Probe(commands: ["kimi"]),
        "kiro-cli": Probe(commands: ["kiro-cli"], apps: ["Kiro", "Kiro CLI"]),
        "kode": Probe(commands: ["kode"]),
        "mistral-vibe": Probe(commands: ["vibe"]),
        "muse": Probe(commands: ["muse"]),
        "neovate": Probe(commands: ["neovate"]),
        "omp": Probe(commands: ["omp"]),
        "openclaude": Probe(commands: ["openclaude"]),
        "openclaw": Probe(commands: ["openclaw"]),
        "opencode": Probe(commands: ["opencode"], apps: ["OpenCode"]),
        "openhands": Probe(commands: ["openhands"]),
        "pi": Probe(commands: ["pi"]),
        "pochi": Probe(commands: ["pochi"]),
        "qoder": Probe(commands: ["qodercli"], apps: ["Qoder"]),
        "qwen-code": Probe(commands: ["qwen"]),
        "reasonix": Probe(commands: ["reasonix"]),
        "roo": Probe(extensions: ["rooveterinaryinc.roo-cline"]),
        "rovodev": Probe(commands: ["acli"]),
        "tabnine-cli": Probe(commands: ["tabnine"]),
        "trae": Probe(apps: ["Trae"]),
        "trae-cn": Probe(apps: ["Trae CN"]),
        "warp": Probe(apps: ["Warp"]),
        "windsurf": Probe(apps: ["Windsurf", "Devin"]),
        "zcode": Probe(apps: ["ZCode"]),
        "zed": Probe(commands: ["zed"], apps: ["Zed"]),
        "zencoder": Probe(extensions: ["zencoderai.zencoder"])
    ]
}
