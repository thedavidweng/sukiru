import Foundation
import Testing

@testable import SukiruCore

/// Spray residue below a config home, and launcher-gated installation.
@Suite("Agent installation")
struct AgentInstallationTests {
    private struct Rig {
        let detector: HostDetector

        init(
            vars: [String: String],
            files: Set<String> = [],
            directories: Set<String> = [],
            entries: [String: [String]] = [:]
        ) {
            let environment = SukiruEnvironment(reader: DictionaryEnvironmentReader(vars))
            let stub = StubFileSystem(
                existing: [], files: files, directories: directories, entries: entries)
            self.detector = HostDetector(environment: environment, fileSystem: stub)
        }
    }

    @Test("Folders holding only nested skills folders or empty folders are spray residue")
    func nestedResidue() {
        let rig = Rig(
            vars: ["SUKIRU_HOME": "/h"],
            directories: [
                "/h/.astrbot", "/h/.astrbot/data", "/h/.config/amp", "/h/.config/amp/plugins"
            ],
            entries: [
                "/h/.astrbot": ["data"], "/h/.astrbot/data": ["skills", ".DS_Store"],
                "/h/.config/amp": ["plugins"], "/h/.config/amp/plugins": []
            ]
        )
        #expect(!rig.detector.marksInstallation("/h/.astrbot"))
        #expect(!rig.detector.marksInstallation("/h/.config/amp"))
        let used = Rig(
            vars: ["SUKIRU_HOME": "/h"],
            directories: ["/h/.astrbot", "/h/.astrbot/data"],
            entries: ["/h/.astrbot": ["data"], "/h/.astrbot/data": ["skills", "config.json"]]
        )
        #expect(used.detector.marksInstallation("/h/.astrbot"))
    }

    @Test("An agent with a known launcher is installed only while the launcher exists")
    func launcherGatesInstallation() {
        let configOnly = Rig(
            vars: ["SUKIRU_HOME": "/h"],
            directories: ["/h/.cline"],
            entries: ["/h/.cline": ["data"]]
        )
        #expect(configOnly.detector.launcherPresent("cline") == false)
        #expect(!configOnly.detector.installedAgentIDs().contains("cline"))
        let viaExtension = Rig(
            vars: ["SUKIRU_HOME": "/h"],
            directories: ["/h/.vscode/extensions"],
            entries: ["/h/.vscode/extensions": ["saoudrizwan.claude-dev-3.20.0"]]
        )
        #expect(viaExtension.detector.installedAgentIDs().contains("cline"))
        let viaApp = Rig(
            vars: ["SUKIRU_HOME": "/h"], directories: ["/h/Applications/Antigravity.app"])
        #expect(viaApp.detector.installedAgentIDs().contains("antigravity"))
        #expect(viaApp.detector.launcherPresent("jazz") == nil)
    }
}
