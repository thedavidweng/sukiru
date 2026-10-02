import Foundation
import Testing

@testable import SukiruCore

/// Guards the embedded host table: the generated Swift
/// data must stay byte-for-byte faithful to `research/host-table.json`, which
/// is the ported source of truth (NOT the ADRs' phantom "116").
@Suite("Host table integrity")
struct HostTableTests {
    /// The checked-in source-of-truth JSON, located relative to this file.
    static let hostTableJSON: URL =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SukiruCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("research/host-table.json")

    private struct HostTableFile: Decodable {
        let hostCount: Int
        let hosts: [HostSpec]
    }

    private static func loadJSON() throws -> HostTableFile {
        let data = try Data(contentsOf: hostTableJSON)
        return try JSONDecoder().decode(HostTableFile.self, from: data)
    }

    @Test("Exactly 77 hosts are embedded (skills@1.7.0)")
    func hostCountIs77() {
        #expect(HostTable.hosts.count == 77)
    }

    @Test("Embedded table matches research/host-table.json exactly")
    func matchesSourceOfTruth() throws {
        let file = try Self.loadJSON()
        #expect(file.hostCount == 77)
        #expect(file.hosts.count == file.hostCount)
        #expect(HostTable.hosts == file.hosts)
    }

    @Test("Required fields are sane for every host")
    func requiredFieldSanity() {
        for host in HostTable.hosts {
            #expect(!host.id.isEmpty, "empty id")
            #expect(!host.displayName.isEmpty, "empty displayName for \(host.id)")
            #expect(!host.projectSkillDir.isEmpty, "empty projectSkillDir for \(host.id)")
            #expect(
                !host.globalSkillDirRelative.isEmpty,
                "empty globalSkillDirRelative for \(host.id)"
            )
            // Env-base hosts must name the env var whose home they resolve.
            if host.globalBase == .env {
                #expect(host.envHomeVar != nil, "env host \(host.id) missing envHomeVar")
                #expect(host.envFallbackDir != nil, "env host \(host.id) missing envFallbackDir")
            }
        }
    }

    @Test("Host ids are unique")
    func idsAreUnique() {
        let ids = HostTable.hosts.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Known special-case hosts are present with the ported semantics")
    func specialCasesPresent() {
        // Empty-marker Env hosts (never fall through to $HOME).
        let envHosts = [
            "autohand-code", "claude-code", "codex", "grok", "hermes-agent", "mistral-vibe"
        ]
        for id in envHosts {
            let host = HostTable.host(id: id)
            #expect(host?.detectionMarker == "", "\(id) should have an empty detection marker")
            #expect(host?.globalBase == .env, "\(id) should resolve its base from an env var")
        }
        // universal and replit are the two hosts hidden from the universal list.
        #expect(HostTable.host(id: "universal")?.showInUniversalList == false)
        #expect(HostTable.host(id: "replit")?.showInUniversalList == false)
        // openclaw carries its two legacy home names as extra markers.
        #expect(HostTable.host(id: "openclaw")?.extraMarkers == [".clawdbot", ".moltbot"])
        // The project-detected hosts — the FULL set is pinned so a
        // host-table edit cannot silently grow it.
        #expect(
            HostTable.hosts.filter { $0.detectInProject }.map { $0.id }
                == ["astrbot", "codebuddy", "continue", "jazz", "replit"])
    }

    @Test("Legacy dirs are pinned and never shadow a current host dir")
    func legacyDirs() {
        let withLegacy = HostTable.hosts.filter {
            !$0.legacyProjectSkillDirs.isEmpty || !$0.legacyGlobalSkillDirs.isEmpty
        }
        #expect(withLegacy.map(\.id) == ["droid", "kilo"])
        #expect(HostTable.host(id: "droid")?.legacyProjectSkillDirs == [".factory/skills"])
        #expect(HostTable.host(id: "kilo")?.legacyProjectSkillDirs == [".kilocode/skills"])
        #expect(HostTable.host(id: "kilo")?.legacyGlobalSkillDirs == [".kilocode/skills"])
        let projectDirs = Set(HostTable.hosts.map(\.projectSkillDir))
        for host in withLegacy {
            for dir in host.legacyProjectSkillDirs {
                #expect(!projectDirs.contains(dir), "\(dir) is a current project dir")
                #expect(HostTable.host(forProjectSkillDir: dir) == nil)
            }
        }
    }

    /// The `--agent` values `gh skill install --help` lists (gh 2.102.0),
    /// minus `antigravity2.0`, which has no skills@1.7.0 host.
    static let ghHelpAgents: Set<String> = [
        "github-copilot", "claude-code", "cursor", "codex", "gemini-cli", "antigravity",
        "antigravity-cli", "adal", "amp", "augment", "bob", "cline", "codebuddy", "command-code",
        "continue", "cortex", "crush", "deepagents", "devin", "droid", "firebender", "goose",
        "grok", "iflow-cli", "junie", "kilo", "kimi-cli", "kiro-cli", "kode", "mcpjam",
        "mistral-vibe", "mux", "neovate", "openclaw", "opencode", "openhands", "pi", "pochi",
        "qoder", "qwen-code", "replit", "roo", "trae", "trae-cn", "universal", "warp", "zencoder"
    ]

    @Test("gh agent ids are exactly gh's --agent values, one host each")
    func ghAgentSubsetIsConsistent() {
        let ghIDs = HostTable.hosts.compactMap(\.ghAgentId)
        #expect(Set(ghIDs).count == ghIDs.count, "a gh agent id maps to two hosts")
        #expect(Set(ghIDs) == Self.ghHelpAgents)
        // gh kept the pre-rename id the skills CLI dropped.
        #expect(HostTable.host(id: "kimi-code-cli")?.ghAgentId == "kimi-cli")
        #expect(HostTable.host(id: "kimi-cli") == nil)
        // Every other gh-accepted host uses its own id.
        for host in HostTable.hosts where host.id != "kimi-code-cli" {
            if let ghID = host.ghAgentId {
                #expect(ghID == host.id, "\(host.id) maps to gh agent \(ghID)")
            }
        }
    }

    @Test("The install sheet only offers gh-accepted agents")
    func ghInstallOptionsAreAccepted() {
        let options = HostTable.ghInstallAgentOptions
        #expect(options == ["codex", "claude-code", "cursor", "gemini-cli"])
        #expect(options.allSatisfy(Self.ghHelpAgents.contains))
    }
}
