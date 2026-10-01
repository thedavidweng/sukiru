import Foundation
import Testing

@testable import SukiruCore

/// Base-resolution semantics for host paths: Home / Xdg /
/// Env bases, empty-string guards, the SUKIRU_HOME hermeticity seam, and the
/// openclaw legacy-name probe order.
@Suite("Host path resolution")
struct HostPathResolverTests {
    private func resolver(
        _ vars: [String: String],
        directories: Set<String> = []
    ) -> HostPathResolver {
        let environment = SukiruEnvironment(reader: DictionaryEnvironmentReader(vars))
        return HostPathResolver(
            environment: environment,
            fileSystem: StubFileSystem(existing: [], directories: directories)
        )
    }

    private func host(_ id: String) throws -> HostSpec {
        try #require(HostTable.host(id: id))
    }

    @Test("join tolerates trailing slashes and empty relatives")
    func joinSemantics() {
        #expect(HostPathResolver.join("/h", ".claude") == "/h/.claude")
        #expect(HostPathResolver.join("/h/", ".claude") == "/h/.claude")
        #expect(HostPathResolver.join("/h", "") == "/h")
    }

    @Test("Home-base host resolves under the home directory")
    func homeBase() throws {
        let resolver = resolver(["SUKIRU_HOME": "/h"])
        #expect(resolver.globalSkillsRoot(for: try host("cursor")) == "/h/.cursor/skills")
    }

    @Test("Xdg base honors the SUKIRU_XDG_CONFIG_HOME override")
    func xdgOverride() throws {
        let vars = ["SUKIRU_HOME": "/h", "SUKIRU_XDG_CONFIG_HOME": "/xdg"]
        let opencode = try host("opencode")
        #expect(resolver(vars).globalSkillsRoot(for: opencode) == "/xdg/opencode/skills")
    }

    @Test("Xdg base falls back to $HOME/.config when the override is empty or unset")
    func xdgFallback() throws {
        let unset = resolver(["SUKIRU_HOME": "/h"])
        #expect(unset.globalSkillsRoot(for: try host("opencode")) == "/h/.config/opencode/skills")
        let empty = resolver(["SUKIRU_HOME": "/h", "SUKIRU_XDG_CONFIG_HOME": ""])
        #expect(empty.globalSkillsRoot(for: try host("opencode")) == "/h/.config/opencode/skills")
    }

    @Test("Env base falls back to $HOME/<envFallbackDir>")
    func envFallback() throws {
        let resolver = resolver(["SUKIRU_HOME": "/h"])
        #expect(resolver.globalSkillsRoot(for: try host("claude-code")) == "/h/.claude/skills")
    }

    @Test("Env base uses the env var when set (real-machine scan)")
    func envVarHonored() throws {
        let vars = ["HOME": "/real", "CLAUDE_CONFIG_DIR": "/custom/claude"]
        let resolver = resolver(vars)
        #expect(resolver.configHome(for: try host("claude-code")) == "/custom/claude")
        #expect(resolver.globalSkillsRoot(for: try host("claude-code")) == "/custom/claude/skills")
    }

    @Test("Env base treats an empty-string env var as unset")
    func envVarEmptyString() throws {
        let vars = ["HOME": "/real", "CLAUDE_CONFIG_DIR": ""]
        let claude = try host("claude-code")
        #expect(resolver(vars).globalSkillsRoot(for: claude) == "/real/.claude/skills")
    }

    @Test("External env vars are suppressed under a SUKIRU_HOME override")
    func hermeticUnderOverride() throws {
        let vars = ["SUKIRU_HOME": "/h", "CLAUDE_CONFIG_DIR": "/custom/claude"]
        let claude = try host("claude-code")
        #expect(resolver(vars).globalSkillsRoot(for: claude) == "/h/.claude/skills")
    }

    @Test("openclaw probes .openclaw, .clawdbot, .moltbot in order")
    func openclawProbeOrder() throws {
        let openclaw = try host("openclaw")
        let both = ["/h/.openclaw", "/h/.clawdbot"]
        let primary = resolver(["SUKIRU_HOME": "/h"], directories: Set(both))
        #expect(primary.globalSkillsRoot(for: openclaw) == "/h/.openclaw/skills")
        let legacyDirs = ["/h/.clawdbot", "/h/.moltbot"]
        let legacy = resolver(["SUKIRU_HOME": "/h"], directories: Set(legacyDirs))
        #expect(legacy.globalSkillsRoot(for: openclaw) == "/h/.clawdbot/skills")
        let oldest = resolver(["SUKIRU_HOME": "/h"], directories: ["/h/.moltbot"])
        #expect(oldest.globalSkillsRoot(for: openclaw) == "/h/.moltbot/skills")
        let none = resolver(["SUKIRU_HOME": "/h"])
        #expect(none.globalSkillsRoot(for: openclaw) == "/h/.openclaw/skills")
    }

    @Test("Project and canonical roots join against the right bases")
    func projectAndCanonicalRoots() throws {
        let resolver = resolver(["SUKIRU_HOME": "/h"])
        let claude = try host("claude-code")
        #expect(resolver.projectSkillsRoot(for: claude, projectRoot: "/p") == "/p/.claude/skills")
        #expect(resolver.canonicalUserRoot() == "/h/.agents/skills")
        #expect(resolver.canonicalProjectRoot(projectRoot: "/p") == "/p/.agents/skills")
    }
}
