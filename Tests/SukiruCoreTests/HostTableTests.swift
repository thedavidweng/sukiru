import Foundation
import Testing

@testable import SukiruCore

/// Guards the embedded 56-host table (architecture §4.1): the generated Swift
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

    @Test("Exactly 56 hosts are embedded")
    func hostCountIs56() {
        #expect(HostTable.hosts.count == 56)
    }

    @Test("Embedded table matches research/host-table.json exactly")
    func matchesSourceOfTruth() throws {
        let file = try Self.loadJSON()
        #expect(file.hostCount == 56)
        #expect(file.hosts.count == 56)
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
        for id in ["claude-code", "codex", "mistral-vibe"] {
            let host = HostTable.host(id: id)
            #expect(host?.detectionMarker == "", "\(id) should have an empty detection marker")
            #expect(host?.globalBase == .env, "\(id) should resolve its base from an env var")
        }
        // universal and replit are the two hosts hidden from the universal list.
        #expect(HostTable.host(id: "universal")?.showInUniversalList == false)
        #expect(HostTable.host(id: "replit")?.showInUniversalList == false)
        // openclaw carries its two legacy home names as extra markers.
        #expect(HostTable.host(id: "openclaw")?.extraMarkers == [".clawdbot", ".moltbot"])
        // codebuddy, continue and replit are the only project-detected
        // hosts — the FULL set is pinned so a host-table edit cannot
        // silently grow it.
        #expect(
            HostTable.hosts.filter { $0.detectInProject }.map { $0.id }
                == ["codebuddy", "continue", "replit"])
    }
}
