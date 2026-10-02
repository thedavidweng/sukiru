// Generated from research/host-table.json by Scripts/generate-host-table.sh.
// Do NOT edit by hand — regenerate instead. Host count: 77.

extension HostTable {
    /// The generated 77-host table backing `HostTable.hosts`.
    static let generatedHosts: [HostSpec] =
        hostsChunk0() + hostsChunk1() + hostsChunk2() + hostsChunk3() + hostsChunk4()
        + hostsChunk5() + hostsChunk6() + hostsChunk7()

    private static func hostsChunk0() -> [HostSpec] {
        var hosts: [HostSpec] = []
        hosts.append(spec("adal", "AdaL", ".adal/skills", ".adal/skills", ".adal", gh: "adal"))
        hosts.append(
            spec(
                "aider-desk", "AiderDesk", ".aider-desk/skills", ".aider-desk/skills", ".aider-desk"
            ))
        hosts.append(
            spec("amp", "Amp", ".agents/skills", "agents/skills", "amp", base: .xdg, gh: "amp"))
        hosts.append(
            spec(
                "antigravity", "Antigravity", ".agents/skills", ".gemini/antigravity/skills",
                ".gemini/antigravity", gh: "antigravity"))
        hosts.append(
            spec(
                "antigravity-cli", "Antigravity CLI", ".agents/skills",
                ".gemini/antigravity-cli/skills", ".gemini/antigravity-cli", gh: "antigravity-cli"))
        hosts.append(
            spec(
                "astrbot", "AstrBot", "data/skills", ".astrbot/data/skills", ".astrbot",
                detectInProject: true))
        hosts.append(
            spec(
                "augment", "Augment", ".augment/skills", ".augment/skills", ".augment",
                gh: "augment"))
        hosts.append(
            spec(
                "autohand-code", "Autohand Code CLI", ".autohand/skills", "skills", "",
                env: "AUTOHAND_HOME", fallback: ".autohand", base: .env))
        hosts.append(spec("bob", "IBM Bob", ".bob/skills", ".bob/skills", ".bob", gh: "bob"))
        hosts.append(
            spec(
                "claude-code", "Claude Code", ".claude/skills", "skills", "",
                env: "CLAUDE_CONFIG_DIR", fallback: ".claude", base: .env, gh: "claude-code"))
        return hosts
    }

    private static func hostsChunk1() -> [HostSpec] {
        var hosts: [HostSpec] = []
        hosts.append(
            spec("cline", "Cline", ".agents/skills", ".agents/skills", ".cline", gh: "cline"))
        hosts.append(
            spec(
                "codearts-agent", "CodeArts Agent", ".codeartsdoer/skills", ".codeartsdoer/skills",
                ".codeartsdoer"))
        hosts.append(
            spec(
                "codebuddy", "CodeBuddy", ".codebuddy/skills", ".codebuddy/skills", ".codebuddy",
                detectInProject: true, gh: "codebuddy"))
        hosts.append(
            spec("codemaker", "Codemaker", ".codemaker/skills", ".codemaker/skills", ".codemaker"))
        hosts.append(
            spec(
                "codestudio", "Code Studio", ".codestudio/skills", ".codestudio/skills",
                ".codestudio"))
        hosts.append(
            spec(
                "codex", "Codex", ".agents/skills", "skills", "", env: "CODEX_HOME",
                fallback: ".codex", base: .env, gh: "codex"))
        hosts.append(
            spec(
                "command-code", "Command Code", ".commandcode/skills", ".commandcode/skills",
                ".commandcode", gh: "command-code"))
        hosts.append(
            spec(
                "continue", "Continue", ".continue/skills", ".continue/skills", ".continue",
                detectInProject: true, gh: "continue"))
        hosts.append(
            spec(
                "cortex", "Cortex Code", ".cortex/skills", ".snowflake/cortex/skills",
                ".snowflake/cortex", gh: "cortex"))
        hosts.append(
            spec(
                "crush", "Crush", ".crush/skills", ".config/crush/skills", ".config/crush",
                gh: "crush"))
        return hosts
    }

    private static func hostsChunk2() -> [HostSpec] {
        var hosts: [HostSpec] = []
        hosts.append(
            spec("cursor", "Cursor", ".agents/skills", ".cursor/skills", ".cursor", gh: "cursor"))
        hosts.append(
            spec(
                "deepagents", "Deep Agents", ".agents/skills", ".deepagents/agent/skills",
                ".deepagents", gh: "deepagents"))
        hosts.append(
            spec(
                "devin", "Devin for Terminal", ".devin/skills", "devin/skills", "devin", base: .xdg,
                gh: "devin"))
        hosts.append(spec("dexto", "Dexto", ".agents/skills", ".agents/skills", ".dexto"))
        hosts.append(
            spec(
                "droid", "Droid", ".agents/skills", ".factory/skills", ".factory",
                legacyProject: [".factory/skills"], gh: "droid"))
        hosts.append(
            spec(
                "firebender", "Firebender", ".agents/skills", ".firebender/skills", ".firebender",
                gh: "firebender"))
        hosts.append(spec("forgecode", "ForgeCode", ".forge/skills", ".forge/skills", ".forge"))
        hosts.append(spec("fx", "fx", ".fx/skills", ".fx/skills", ".fx"))
        hosts.append(
            spec(
                "gemini-cli", "Gemini CLI", ".agents/skills", ".gemini/skills", ".gemini",
                gh: "gemini-cli"))
        hosts.append(
            spec(
                "github-copilot", "GitHub Copilot", ".agents/skills", ".copilot/skills", ".copilot",
                gh: "github-copilot"))
        return hosts
    }

    private static func hostsChunk3() -> [HostSpec] {
        var hosts: [HostSpec] = []
        hosts.append(
            spec(
                "goose", "Goose", ".goose/skills", "goose/skills", "goose", base: .xdg, gh: "goose")
        )
        hosts.append(
            spec(
                "grok", "Grok Build", ".grok/skills", "skills", "", env: "GROK_HOME",
                fallback: ".grok", base: .env, gh: "grok"))
        hosts.append(
            spec(
                "hermes-agent", "Hermes Agent", ".hermes/skills", "skills", "", env: "HERMES_HOME",
                fallback: ".hermes", base: .env))
        hosts.append(
            spec(
                "iflow-cli", "iFlow CLI", ".iflow/skills", ".iflow/skills", ".iflow",
                gh: "iflow-cli"))
        hosts.append(
            spec(
                "inference-sh", "inference.sh", ".inferencesh/skills", ".inferencesh/skills",
                ".inferencesh"))
        hosts.append(
            spec("jazz", "Jazz", ".jazz/skills", ".jazz/skills", ".jazz", detectInProject: true))
        hosts.append(
            spec("junie", "Junie", ".junie/skills", ".junie/skills", ".junie", gh: "junie"))
        hosts.append(
            spec(
                "kilo", "Kilo Code", ".agents/skills", ".kilo/skills", ".kilo",
                extra: [".kilocode"], legacyProject: [".kilocode/skills"],
                legacyGlobal: [".kilocode/skills"], gh: "kilo"))
        hosts.append(
            spec(
                "kimchi", "Kimchi", ".kimchi/skills", ".config/kimchi/harness/skills",
                ".config/kimchi"))
        hosts.append(
            spec(
                "kimi-code-cli", "Kimi Code CLI", ".agents/skills", ".agents/skills", ".kimi-code",
                extra: [".kimi"], gh: "kimi-cli"))
        return hosts
    }

    private static func hostsChunk4() -> [HostSpec] {
        var hosts: [HostSpec] = []
        hosts.append(
            spec("kiro-cli", "Kiro CLI", ".kiro/skills", ".kiro/skills", ".kiro", gh: "kiro-cli"))
        hosts.append(spec("kode", "Kode", ".kode/skills", ".kode/skills", ".kode", gh: "kode"))
        hosts.append(spec("lingma", "Lingma", ".lingma/skills", ".lingma/skills", ".lingma"))
        hosts.append(spec("loaf", "Loaf", ".agents/skills", ".agents/skills", ".loaf"))
        hosts.append(
            spec("mcpjam", "MCPJam", ".mcpjam/skills", ".mcpjam/skills", ".mcpjam", gh: "mcpjam"))
        hosts.append(
            spec("minimax-code", "MiniMax Code", ".minimax/skills", ".minimax/skills", ".minimax"))
        hosts.append(
            spec(
                "mistral-vibe", "Mistral Vibe", ".vibe/skills", "skills", "", env: "VIBE_HOME",
                fallback: ".vibe", base: .env, gh: "mistral-vibe"))
        hosts.append(spec("moxby", "Moxby", ".moxby/skills", ".moxby/skills", ".moxby"))
        hosts.append(spec("mux", "Mux", ".mux/skills", ".mux/skills", ".mux", gh: "mux"))
        hosts.append(
            spec(
                "neovate", "Neovate", ".neovate/skills", ".neovate/skills", ".neovate",
                gh: "neovate"))
        return hosts
    }

    private static func hostsChunk5() -> [HostSpec] {
        var hosts: [HostSpec] = []
        hosts.append(spec("ona", "Ona", ".ona/skills", ".ona/skills", ".ona"))
        hosts.append(
            spec(
                "openclaw", "OpenClaw", "skills", ".openclaw/skills", ".openclaw",
                extra: [".clawdbot", ".moltbot"], gh: "openclaw"))
        hosts.append(
            spec(
                "opencode", "OpenCode", ".agents/skills", "opencode/skills", "opencode", base: .xdg,
                gh: "opencode"))
        hosts.append(
            spec(
                "openhands", "OpenHands", ".openhands/skills", ".openhands/skills", ".openhands",
                gh: "openhands"))
        hosts.append(spec("pi", "Pi", ".pi/skills", ".pi/agent/skills", ".pi/agent", gh: "pi"))
        hosts.append(
            spec("pochi", "Pochi", ".pochi/skills", ".pochi/skills", ".pochi", gh: "pochi"))
        hosts.append(
            spec(
                "posit-assistant", "Posit Assistant", ".posit/assistant/skills",
                ".posit/assistant/skills", ".posit/assistant", extra: [".positai"]))
        hosts.append(
            spec("qoder", "Qoder", ".qoder/skills", ".qoder/skills", ".qoder", gh: "qoder"))
        hosts.append(spec("qoder-cn", "Qoder CN", ".qoder/skills", ".qoder-cn/skills", ".qoder-cn"))
        hosts.append(
            spec("qwen-code", "Qwen Code", ".qwen/skills", ".qwen/skills", ".qwen", gh: "qwen-code")
        )
        return hosts
    }

    private static func hostsChunk6() -> [HostSpec] {
        var hosts: [HostSpec] = []
        hosts.append(
            spec("reasonix", "Reasonix", ".reasonix/skills", ".reasonix/skills", ".reasonix"))
        hosts.append(
            spec(
                "replit", "Replit", ".agents/skills", "agents/skills", ".replit", base: .xdg,
                detectInProject: true, universal: false, gh: "replit"))
        hosts.append(spec("roo", "Roo Code", ".roo/skills", ".roo/skills", ".roo", gh: "roo"))
        hosts.append(spec("rovodev", "Rovo Dev", ".rovodev/skills", ".rovodev/skills", ".rovodev"))
        hosts.append(
            spec("sarvam-code", "Sarvam Code", ".agents/skills", ".agents/skills", ".sarvam"))
        hosts.append(
            spec(
                "tabnine-cli", "Tabnine CLI", ".tabnine/agent/skills", ".tabnine/agent/skills",
                ".tabnine"))
        hosts.append(
            spec("terramind", "Terramind", ".terramind/skills", ".terramind/skills", ".terramind"))
        hosts.append(
            spec("tinycloud", "Tinycloud", ".tinycloud/skills", ".tinycloud/skills", ".tinycloud"))
        hosts.append(spec("trae", "Trae", ".trae/skills", ".trae/skills", ".trae", gh: "trae"))
        hosts.append(
            spec("trae-cn", "Trae CN", ".trae/skills", ".trae-cn/skills", ".trae-cn", gh: "trae-cn")
        )
        return hosts
    }

    private static func hostsChunk7() -> [HostSpec] {
        var hosts: [HostSpec] = []
        hosts.append(
            spec(
                "universal", "Universal", ".agents/skills", "agents/skills", "agents", base: .xdg,
                universal: false, gh: "universal"))
        hosts.append(spec("warp", "Warp", ".agents/skills", ".agents/skills", ".warp", gh: "warp"))
        hosts.append(
            spec(
                "windsurf", "Windsurf", ".windsurf/skills", ".codeium/windsurf/skills",
                ".codeium/windsurf"))
        hosts.append(spec("zcode", "ZCode", ".zcode/skills", ".zcode/skills", ".zcode"))
        hosts.append(spec("zed", "Zed", ".agents/skills", ".agents/skills", ".config/zed"))
        hosts.append(
            spec(
                "zencoder", "Zencoder", ".zencoder/skills", ".zencoder/skills", ".zencoder",
                gh: "zencoder"))
        hosts.append(
            spec("zenflow", "Zenflow", ".zencoder/skills", ".zencoder/skills", ".zencoder"))
        return hosts
    }

    // swift-format-ignore: NeverUseImplicitlyUnwrappedOptionals
    private static func spec(
        _ id: String,
        _ displayName: String,
        _ projectSkillDir: String,
        _ globalSkillDirRelative: String,
        _ detectionMarker: String,
        env envHomeVar: String? = nil,
        fallback envFallbackDir: String? = nil,
        extra extraMarkers: [String] = [],
        base globalBase: HostSpec.GlobalBase = .home,
        detectInProject: Bool = false,
        universal showInUniversalList: Bool = true,
        legacyProject legacyProjectSkillDirs: [String] = [],
        legacyGlobal legacyGlobalSkillDirs: [String] = [],
        gh ghAgentId: String? = nil
    ) -> HostSpec {
        HostSpec(
            id: id,
            displayName: displayName,
            projectSkillDir: projectSkillDir,
            globalSkillDirRelative: globalSkillDirRelative,
            detectionMarker: detectionMarker,
            envHomeVar: envHomeVar,
            envFallbackDir: envFallbackDir,
            extraMarkers: extraMarkers,
            globalBase: globalBase,
            detectInProject: detectInProject,
            showInUniversalList: showInUniversalList,
            legacyProjectSkillDirs: legacyProjectSkillDirs,
            legacyGlobalSkillDirs: legacyGlobalSkillDirs,
            ghAgentId: ghAgentId
        )
    }
}
