import Foundation
import Testing

@testable import SukiruCore

/// Ordered host detection and the load-bearing `marks_installation` rule
/// (architecture §4.1, port-reference §1–2; validation VAL-SCAN-012/013/014).
@Suite("Host detection")
struct HostDetectorTests {
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
                existing: [],
                files: files,
                directories: directories,
                entries: entries
            )
            self.detector = HostDetector(environment: environment, fileSystem: stub)
        }
    }

    private func host(_ id: String) throws -> HostSpec {
        try #require(HostTable.host(id: id))
    }

    // MARK: marks_installation

    @Test("A plain file always marks an installation")
    func plainFileMarks() {
        let rig = Rig(vars: ["SUKIRU_HOME": "/h"], files: ["/h/.qoder"])
        #expect(rig.detector.marksInstallation("/h/.qoder"))
    }

    @Test("A missing path does not mark an installation")
    func missingPathDoesNotMark() {
        let rig = Rig(vars: ["SUKIRU_HOME": "/h"])
        #expect(!rig.detector.marksInstallation("/h/.qoder"))
    }

    @Test("An unreadable directory falls back to plain existence (counts)")
    func unreadableDirMarks() {
        // Directory present but its entries cannot be listed (nil).
        let rig = Rig(vars: ["SUKIRU_HOME": "/h"], directories: ["/h/.qoder"])
        #expect(rig.detector.marksInstallation("/h/.qoder"))
    }

    @Test("A directory whose entire content is a bare skills entry is spray residue")
    func bareSkillsIsResidue() {
        let rig = Rig(
            vars: ["SUKIRU_HOME": "/h"],
            directories: ["/h/.qoder"],
            entries: ["/h/.qoder": ["skills"]]
        )
        #expect(!rig.detector.marksInstallation("/h/.qoder"))
    }

    @Test(".DS_Store and .localized never flip residue into an installation")
    func dsStoreAndLocalizedIgnored() {
        let rig = Rig(
            vars: ["SUKIRU_HOME": "/h"],
            directories: ["/h/.qoder"],
            entries: ["/h/.qoder": ["skills", ".DS_Store", ".localized"]]
        )
        #expect(!rig.detector.marksInstallation("/h/.qoder"))
    }

    @Test("A real config file alongside skills marks an installation")
    func skillsPlusConfigMarks() {
        let rig = Rig(
            vars: ["SUKIRU_HOME": "/h"],
            directories: ["/h/.qoder"],
            entries: ["/h/.qoder": ["skills", "config.json"]]
        )
        #expect(rig.detector.marksInstallation("/h/.qoder"))
    }

    @Test("Directories without a skills entry count as installations")
    func noSkillsEntryMarks() {
        let dsOnly = Rig(
            vars: ["SUKIRU_HOME": "/h"],
            directories: ["/h/.qoder"],
            entries: ["/h/.qoder": [".DS_Store"]]
        )
        #expect(dsOnly.detector.marksInstallation("/h/.qoder"))
        let empty = Rig(
            vars: ["SUKIRU_HOME": "/h"],
            directories: ["/h/.qoder"],
            entries: ["/h/.qoder": []]
        )
        #expect(empty.detector.marksInstallation("/h/.qoder"))
    }

    // MARK: isDetected ordering

    @Test("universal is never detected, even when its layout exists")
    func universalNeverDetected() throws {
        let rig = Rig(
            vars: ["SUKIRU_HOME": "/h"],
            directories: ["/h/.config/agents"],
            entries: ["/h/.config/agents": ["skills", "config"]]
        )
        #expect(!rig.detector.isDetected(try host("universal")))
    }

    @Test("codex short-circuits true on the absolute /etc/codex marker")
    func codexEtcMarker() throws {
        let rig = Rig(vars: ["SUKIRU_HOME": "/h"], files: ["/etc/codex"])
        #expect(rig.detector.isDetected(try host("codex")))
    }

    @Test("replit is cwd-only: never detected by home content in user scope")
    func replitCwdOnly() throws {
        let rig = Rig(vars: ["SUKIRU_HOME": "/h"], files: ["/h/.replit"])
        #expect(!rig.detector.isDetected(try host("replit")))
    }

    @Test("zed probes the XDG config base, then APPDATA, then FLATPAK")
    func zedProbes() throws {
        let xdg = Rig(
            vars: ["SUKIRU_HOME": "/h", "SUKIRU_XDG_CONFIG_HOME": "/xdg"],
            directories: ["/xdg/zed"]
        )
        #expect(xdg.detector.isDetected(try host("zed")))

        // APPDATA is an external variable: honored on a real-machine scan …
        let appData = Rig(
            vars: ["HOME": "/real", "APPDATA": "/roaming"],
            directories: ["/roaming/Zed"]
        )
        #expect(appData.detector.isDetected(try host("zed")))
        // … but suppressed under a SUKIRU_HOME override (hermeticity).
        let suppressed = Rig(
            vars: ["SUKIRU_HOME": "/h", "APPDATA": "/roaming"],
            directories: ["/roaming/Zed"]
        )
        #expect(!suppressed.detector.isDetected(try host("zed")))

        let flatpak = Rig(
            vars: ["HOME": "/real", "FLATPAK_XDG_CONFIG_HOME": "/flatpak"],
            directories: ["/flatpak/zed"]
        )
        #expect(flatpak.detector.isDetected(try host("zed")))

        let absent = Rig(vars: ["SUKIRU_HOME": "/h"])
        #expect(!absent.detector.isDetected(try host("zed")))
    }

    @Test("Empty-marker hosts probe the resolved base and never fall through to $HOME")
    func emptyMarkerNoFallthrough() throws {
        // $HOME has unrelated content but no .claude: claude-code must NOT be
        // detected (VAL-SCAN-014).
        let rig = Rig(
            vars: ["SUKIRU_HOME": "/h"],
            files: ["/h/notes.txt"],
            directories: ["/h", "/h/Projects"],
            entries: ["/h": ["notes.txt", "Projects"]]
        )
        #expect(!rig.detector.isDetected(try host("claude-code")))
        #expect(!rig.detector.isDetected(try host("codex")))
        #expect(!rig.detector.isDetected(try host("mistral-vibe")))
    }

    @Test("Empty-marker host detected when the resolved base marks an installation")
    func emptyMarkerDetected() throws {
        let rig = Rig(
            vars: ["SUKIRU_HOME": "/h"],
            directories: ["/h/.claude"],
            entries: ["/h/.claude": ["skills", "config.json"]]
        )
        #expect(rig.detector.isDetected(try host("claude-code")))
    }

    @Test("Env var homes resolve the empty-marker probe (real-machine scan)")
    func emptyMarkerEnvVar() throws {
        let rig = Rig(
            vars: ["HOME": "/real", "CLAUDE_CONFIG_DIR": "/custom"],
            directories: ["/custom"],
            entries: ["/custom": ["skills", "settings.json"]]
        )
        #expect(rig.detector.isDetected(try host("claude-code")))
    }

    @Test("Marker hosts probe base-relative then $HOME-relative markers")
    func markerProbes() throws {
        let home = Rig(
            vars: ["SUKIRU_HOME": "/h"],
            directories: ["/h/.roo"],
            entries: ["/h/.roo": ["skills", "config.json"]]
        )
        #expect(home.detector.isDetected(try host("roo")))
        let absent = Rig(vars: ["SUKIRU_HOME": "/h"])
        #expect(!absent.detector.isDetected(try host("roo")))
    }

    @Test("openclaw is detected via its legacy extra markers")
    func openclawExtraMarkers() throws {
        let rig = Rig(
            vars: ["SUKIRU_HOME": "/h"],
            directories: ["/h/.clawdbot"],
            entries: ["/h/.clawdbot": ["config.toml"]]
        )
        #expect(rig.detector.isDetected(try host("openclaw")))
        let absent = Rig(vars: ["SUKIRU_HOME": "/h"])
        #expect(!absent.detector.isDetected(try host("openclaw")))
    }

    @Test("detectInProject hosts still fall through to home probes in user scope")
    func detectInProjectFallsThrough() throws {
        let home = Rig(
            vars: ["SUKIRU_HOME": "/h"],
            directories: ["/h/.codebuddy"],
            entries: ["/h/.codebuddy": ["config.json"]]
        )
        #expect(home.detector.isDetected(try host("codebuddy")))
        let absent = Rig(vars: ["SUKIRU_HOME": "/h"])
        #expect(!absent.detector.isDetected(try host("codebuddy")))
    }

    // MARK: Tri-state

    @Test("Detected host yields .detected")
    func stateDetected() throws {
        let rig = Rig(
            vars: ["SUKIRU_HOME": "/h"],
            directories: ["/h/.qoder", "/h/.qoder/skills"],
            entries: ["/h/.qoder": ["skills", "config.json"]]
        )
        #expect(rig.detector.detectionState(for: try host("qoder")) == .detected)
    }

    @Test("Spray-residue host with an existing skills root yields .leftover")
    func stateLeftover() throws {
        let rig = Rig(
            vars: ["SUKIRU_HOME": "/h"],
            directories: ["/h/.qoder", "/h/.qoder/skills"],
            entries: ["/h/.qoder": ["skills"]]
        )
        #expect(rig.detector.detectionState(for: try host("qoder")) == .leftover)
    }

    @Test("Undetected host with no skills root on disk yields .absent")
    func stateAbsent() throws {
        let rig = Rig(vars: ["SUKIRU_HOME": "/h"])
        #expect(rig.detector.detectionState(for: try host("qoder")) == .absent)
    }

    @Test("Empty-marker host with residue yields .leftover, not a $HOME fallthrough")
    func emptyMarkerLeftover() throws {
        // .claude contains only a bare skills entry (spray residue) while $HOME
        // itself has plenty of other content.
        let rig = Rig(
            vars: ["SUKIRU_HOME": "/h"],
            files: ["/h/notes.txt"],
            directories: ["/h", "/h/.claude", "/h/.claude/skills"],
            entries: ["/h": ["notes.txt", ".claude"], "/h/.claude": ["skills"]]
        )
        #expect(rig.detector.detectionState(for: try host("claude-code")) == .leftover)
    }
}
