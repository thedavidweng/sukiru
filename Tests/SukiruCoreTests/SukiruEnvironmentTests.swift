import Foundation
import Testing

@testable import SukiruCore

/// In-memory filesystem probe so exit-code logic is unit-testable without disk.
struct StubFileSystem: FileSystemProbe {
    let existing: Set<String>
    var files: Set<String> = []
    var directories: Set<String> = []
    var entries: [String: [String]] = [:]
    var contents: [String: Data] = [:]
    var symlinks: [String: String] = [:]

    func exists(atPath path: String) -> Bool {
        existing.contains(path) || files.contains(path) || directories.contains(path)
    }

    func isFile(atPath path: String) -> Bool {
        files.contains(path)
    }

    func isDirectory(atPath path: String) -> Bool {
        directories.contains(path)
    }

    func directoryEntries(atPath path: String) -> [String]? {
        entries[path]
    }

    func fileContents(atPath path: String) -> Data? {
        contents[path]
    }

    func entryKind(atPath path: String) -> EntryKind? {
        if let target = symlinks[path] { return .symlink(target: target) }
        if files.contains(path) { return .file }
        if directories.contains(path) { return .directory }
        return nil
    }

    func resolvedPath(atPath path: String) -> String? {
        exists(atPath: path) ? path : nil
    }
}

@Suite("SukiruEnvironment override seam")
struct SukiruEnvironmentTests {
    @Test("SUKIRU_HOME overrides HOME and is marked overridden")
    func sukiruHomeOverrides() {
        let vars = ["HOME": "/real/home", "SUKIRU_HOME": "/fixture/home"]
        let env = SukiruEnvironment(reader: DictionaryEnvironmentReader(vars))
        #expect(env.home == "/fixture/home")
        #expect(env.homeIsOverridden)
    }

    @Test("Falls back to HOME when SUKIRU_HOME is unset")
    func fallsBackToHome() {
        let env = SukiruEnvironment(reader: DictionaryEnvironmentReader(["HOME": "/real/home"]))
        #expect(env.home == "/real/home")
        #expect(!env.homeIsOverridden)
    }

    @Test("Empty SUKIRU_HOME is treated as unset")
    func emptyHomeIsUnset() {
        let vars = ["HOME": "/real/home", "SUKIRU_HOME": ""]
        let env = SukiruEnvironment(reader: DictionaryEnvironmentReader(vars))
        #expect(env.home == "/real/home")
        #expect(!env.homeIsOverridden)
    }

    @Test("SUKIRU_ROOTS splits on colons, preserving order")
    func rootsSplit() {
        let vars = ["SUKIRU_ROOTS": "/a:/b:/c"]
        let env = SukiruEnvironment(reader: DictionaryEnvironmentReader(vars))
        #expect(env.projectRoots == ["/a", "/b", "/c"])
    }

    @Test("Empty SUKIRU_ROOTS yields no roots")
    func rootsEmpty() {
        let env = SukiruEnvironment(reader: DictionaryEnvironmentReader(["SUKIRU_ROOTS": ""]))
        #expect(env.projectRoots.isEmpty)
    }

    @Test("XDG overrides are nil when unset or empty, value when set")
    func xdgOverrides() {
        let present = ["SUKIRU_XDG_CONFIG_HOME": "/cfg", "SUKIRU_XDG_STATE_HOME": "/state"]
        let set = SukiruEnvironment(reader: DictionaryEnvironmentReader(present))
        #expect(set.xdgConfigHome == "/cfg")
        #expect(set.xdgStateHome == "/state")

        let blank = ["SUKIRU_XDG_CONFIG_HOME": "", "SUKIRU_XDG_STATE_HOME": ""]
        let empty = SukiruEnvironment(reader: DictionaryEnvironmentReader(blank))
        #expect(empty.xdgConfigHome == nil)
        #expect(empty.xdgStateHome == nil)
    }

    @Test("Fatal problem fires only when an overridden home is missing")
    func fatalProblem() {
        let nopeVars = ["SUKIRU_HOME": "/nope"]
        let missing = SukiruEnvironment(reader: DictionaryEnvironmentReader(nopeVars))
        let missingProblem = missing.fatalProblem(fileSystem: StubFileSystem(existing: []))
        #expect(missingProblem == .sukiruHomeMissing(path: "/nope"))

        let hereVars = ["SUKIRU_HOME": "/here"]
        let present = SukiruEnvironment(reader: DictionaryEnvironmentReader(hereVars))
        let presentProblem = present.fatalProblem(fileSystem: StubFileSystem(existing: ["/here"]))
        #expect(presentProblem == nil)

        let unset = SukiruEnvironment(reader: DictionaryEnvironmentReader(["HOME": "/real"]))
        #expect(unset.fatalProblem(fileSystem: StubFileSystem(existing: [])) == nil)
    }
}
