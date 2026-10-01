import Foundation
import Testing

@testable import SukiruCore

/// Finding Node.js installed through version managers, for an app whose
/// PATH is launchd's minimal one.
@Suite("Node.js toolchain discovery")
struct NodeToolchainTests {
    private let npx = "#!/bin/sh\nexit 0\n"

    @Test("Manager directories count only when they hold an npx")
    func managerBinDirectories() throws {
        let tree = try TempTree()
        _ = try tree.executable(".local/share/mise/shims/npx", contents: npx)
        _ = try tree.executable(".volta/bin/npx", contents: npx)
        _ = try tree.dir(".asdf/shims")
        _ = try tree.executable(
            "Library/Application Support/fnm/aliases/default/bin/npx", contents: npx)
        let dirs = NodeToolchain(home: tree.path).managerBinDirectories()
        #expect(
            dirs == [
                tree.path + "/.local/share/mise/shims",
                tree.path + "/.volta/bin",
                tree.path + "/Library/Application Support/fnm/aliases/default/bin"
            ])
    }

    @Test("nvm: the default alias picks the newest matching installed version")
    func nvmDefaultAlias() throws {
        let tree = try TempTree()
        for version in ["v20.18.0", "v22.9.0", "v22.11.0", "v24.1.0"] {
            _ = try tree.executable(".nvm/versions/node/\(version)/bin/npx", contents: npx)
        }
        let toolchain = NodeToolchain(home: tree.path)
        let versions = tree.path + "/.nvm/versions/node"

        _ = try tree.file(".nvm/alias/default", contents: "22\n")
        #expect(toolchain.nvmDefaultBin() == versions + "/v22.11.0/bin")

        _ = try tree.file(".nvm/alias/default", contents: "v20.18.0")
        #expect(toolchain.nvmDefaultBin() == versions + "/v20.18.0/bin")

        _ = try tree.file(".nvm/alias/default", contents: "lts/*")
        #expect(toolchain.nvmDefaultBin() == versions + "/v24.1.0/bin")
    }

    @Test("nvm without installed versions contributes nothing")
    func nvmEmpty() throws {
        let tree = try TempTree()
        _ = try tree.dir(".nvm")
        #expect(NodeToolchain(home: tree.path).nvmDefaultBin() == nil)
    }

    @Test("Installed managers come from data directories or executables on PATH")
    func installedManagers() throws {
        let tree = try TempTree()
        _ = try tree.dir(".nvm")
        let bin = try tree.dir("bin")
        _ = try tree.executable("bin/fnm", contents: npx)
        let toolchain = NodeToolchain(home: tree.path)
        #expect(toolchain.installedManagers(searchPath: "/usr/bin:\(bin)") == [.fnm, .nvm])
        #expect(NodeToolchain(home: tree.path + "/none").installedManagers(searchPath: "") == [])
    }

    @Test("Search path keeps the first occurrence of each entry")
    func searchPathMerge() {
        let merged = NodeToolchain.searchPath([
            ["/mise/node/bin", "/usr/bin"], ["/usr/bin", "", "/bin"], ["/mise/node/bin", "/volta"]
        ])
        #expect(merged == "/mise/node/bin:/usr/bin:/bin:/volta")
    }

    @Test("The shell's PATH is read between markers, ignoring startup noise")
    func extractPath() {
        let marker = LoginShell.marker
        #expect(
            LoginShell.extractPath(from: "Welcome!\n\(marker)/a/bin:/usr/bin\(marker)")
                == "/a/bin:/usr/bin")
        #expect(LoginShell.extractPath(from: "no markers here") == nil)
        #expect(LoginShell.extractPath(from: "\(marker)\(marker)") == nil)
    }
}
