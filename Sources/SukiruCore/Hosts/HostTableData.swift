// Generated from research/host-table.json by Scripts/generate-host-table.sh.
// Do NOT edit by hand — regenerate instead. Host count: 56.

extension HostTable {
    /// The generated 56-host table backing `HostTable.hosts`.
    static let generatedHosts: [HostSpec] =
        hostsChunk0() + hostsChunk1() + hostsChunk2() + hostsChunk3() + hostsChunk4()
        + hostsChunk5()

    private static func hostsChunk0() -> [HostSpec] {
        var hosts: [HostSpec] = []
        hosts.append(spec("adal", "AdaL", ".adal/skills", ".adal/skills", ".adal"))
        hosts.append(
            spec(
                "aider-desk", "AiderDesk", ".aider-desk/skills", ".aider-desk/skills", ".aider-desk"
            ))
        hosts.append(spec("amp", "Amp", ".agents/skills", "agents/skills", "amp", base: .xdg))
        hosts.append(
            spec(
                "antigravity", "Antigravity", ".agents/skills", ".gemini/antigravity/skills",
                ".gemini/antigravity"))
        hosts.append(spec("augment", "Augment", ".augment/skills", ".augment/skills", ".augment"))
        hosts.append(spec("bob", "IBM Bob", ".bob/skills", ".bob/skills", ".bob"))
        hosts.append(
            spec(
                "claude-code", "Claude Code", ".claude/skills", "skills", "",
                env: "CLAUDE_CONFIG_DIR", fallback: ".claude", base: .env))
        hosts.append(spec("cline", "Cline", ".agents/skills", ".agents/skills", ".cline"))
        hosts.append(
            spec(
                "codearts-agent", "CodeArts Agent", ".codeartsdoer/skills", ".codeartsdoer/skills",
                ".codeartsdoer"))
        hosts.append(
            spec(
                "codebuddy", "CodeBuddy", ".codebuddy/skills", ".codebuddy/skills", ".codebuddy",
                detectInProject: true))
        return hosts
    }

    private static func hostsChunk1() -> [HostSpec] {
        var hosts: [HostSpec] = []
        hosts.append(
            spec("codemaker", "Codemaker", ".codemaker/skills", ".codemaker/skills", ".codemaker"))
        hosts.append(
            spec(
                "codestudio", "Code Studio", ".codestudio/skills", ".codestudio/skills",
                ".codestudio"))
        hosts.append(
            spec(
                "codex", "Codex", ".agents/skills", "skills", "", env: "CODEX_HOME",
                fallback: ".codex", base: .env))
        hosts.append(
            spec(
                "command-code", "Command Code", ".commandcode/skills", ".commandcode/skills",
                ".commandcode"))
        hosts.append(
            spec(
                "continue", "Continue", ".continue/skills", ".continue/skills", ".continue",
                detectInProject: true))
        hosts.append(
            spec(
                "cortex", "Cortex Code", ".cortex/skills", ".snowflake/cortex/skills",
                ".snowflake/cortex"))
        hosts.append(
            spec("crush", "Crush", ".crush/skills", ".config/crush/skills", ".config/crush"))
        hosts.append(spec("cursor", "Cursor", ".agents/skills", ".cursor/skills", ".cursor"))
        hosts.append(
            spec(
                "deepagents", "Deep Agents", ".agents/skills", ".deepagents/agent/skills",
                ".deepagents"))
        hosts.append(
            spec(
                "devin", "Devin for Terminal", ".devin/skills", "devin/skills", "devin", base: .xdg)
        )
        return hosts
    }

    private static func hostsChunk2() -> [HostSpec] {
        var hosts: [HostSpec] = []
        hosts.append(spec("dexto", "Dexto", ".agents/skills", ".agents/skills", ".dexto"))
        hosts.append(spec("droid", "Droid", ".factory/skills", ".factory/skills", ".factory"))
        hosts.append(
            spec("firebender", "Firebender", ".agents/skills", ".firebender/skills", ".firebender"))
        hosts.append(spec("forgecode", "ForgeCode", ".forge/skills", ".forge/skills", ".forge"))
        hosts.append(
            spec("gemini-cli", "Gemini CLI", ".agents/skills", ".gemini/skills", ".gemini"))
        hosts.append(
            spec(
                "github-copilot", "GitHub Copilot", ".agents/skills", ".copilot/skills", ".copilot")
        )
        hosts.append(spec("goose", "Goose", ".goose/skills", "goose/skills", "goose", base: .xdg))
        hosts.append(
            spec("hermes-agent", "Hermes Agent", ".hermes/skills", ".hermes/skills", ".hermes"))
        hosts.append(spec("iflow-cli", "iFlow CLI", ".iflow/skills", ".iflow/skills", ".iflow"))
        hosts.append(spec("junie", "Junie", ".junie/skills", ".junie/skills", ".junie"))
        return hosts
    }

    private static func hostsChunk3() -> [HostSpec] {
        var hosts: [HostSpec] = []
        hosts.append(spec("kilo", "Kilo Code", ".kilocode/skills", ".kilocode/skills", ".kilocode"))
        hosts.append(
            spec("kimi-cli", "Kimi Code CLI", ".agents/skills", ".config/agents/skills", ".kimi"))
        hosts.append(spec("kiro-cli", "Kiro CLI", ".kiro/skills", ".kiro/skills", ".kiro"))
        hosts.append(spec("kode", "Kode", ".kode/skills", ".kode/skills", ".kode"))
        hosts.append(spec("mcpjam", "MCPJam", ".mcpjam/skills", ".mcpjam/skills", ".mcpjam"))
        hosts.append(
            spec(
                "mistral-vibe", "Mistral Vibe", ".vibe/skills", "skills", "", env: "VIBE_HOME",
                fallback: ".vibe", base: .env))
        hosts.append(spec("mux", "Mux", ".mux/skills", ".mux/skills", ".mux"))
        hosts.append(spec("neovate", "Neovate", ".neovate/skills", ".neovate/skills", ".neovate"))
        hosts.append(
            spec(
                "openclaw", "OpenClaw", "skills", ".openclaw/skills", ".openclaw",
                extra: [".clawdbot", ".moltbot"]))
        hosts.append(
            spec(
                "opencode", "OpenCode", ".agents/skills", "opencode/skills", "opencode", base: .xdg)
        )
        return hosts
    }

    private static func hostsChunk4() -> [HostSpec] {
        var hosts: [HostSpec] = []
        hosts.append(
            spec("openhands", "OpenHands", ".openhands/skills", ".openhands/skills", ".openhands"))
        hosts.append(spec("pi", "Pi", ".pi/skills", ".pi/agent/skills", ".pi/agent"))
        hosts.append(spec("pochi", "Pochi", ".pochi/skills", ".pochi/skills", ".pochi"))
        hosts.append(spec("qoder", "Qoder", ".qoder/skills", ".qoder/skills", ".qoder"))
        hosts.append(spec("qwen-code", "Qwen Code", ".qwen/skills", ".qwen/skills", ".qwen"))
        hosts.append(
            spec(
                "replit", "Replit", ".agents/skills", "agents/skills", ".replit", base: .xdg,
                detectInProject: true, universal: false))
        hosts.append(spec("roo", "Roo Code", ".roo/skills", ".roo/skills", ".roo"))
        hosts.append(spec("rovodev", "Rovo Dev", ".rovodev/skills", ".rovodev/skills", ".rovodev"))
        hosts.append(
            spec(
                "tabnine-cli", "Tabnine CLI", ".tabnine/agent/skills", ".tabnine/agent/skills",
                ".tabnine"))
        hosts.append(spec("trae", "Trae", ".trae/skills", ".trae/skills", ".trae"))
        return hosts
    }

    private static func hostsChunk5() -> [HostSpec] {
        var hosts: [HostSpec] = []
        hosts.append(spec("trae-cn", "Trae CN", ".trae/skills", ".trae-cn/skills", ".trae-cn"))
        hosts.append(
            spec(
                "universal", "Universal", ".agents/skills", "agents/skills", "agents", base: .xdg,
                universal: false))
        hosts.append(spec("warp", "Warp", ".agents/skills", ".agents/skills", ".warp"))
        hosts.append(
            spec(
                "windsurf", "Windsurf", ".windsurf/skills", ".codeium/windsurf/skills",
                ".codeium/windsurf"))
        hosts.append(spec("zed", "Zed", ".agents/skills", ".agents/skills", ".config/zed"))
        hosts.append(
            spec("zencoder", "Zencoder", ".zencoder/skills", ".zencoder/skills", ".zencoder"))
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
        universal showInUniversalList: Bool = true
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
            showInUniversalList: showInUniversalList
        )
    }
}
