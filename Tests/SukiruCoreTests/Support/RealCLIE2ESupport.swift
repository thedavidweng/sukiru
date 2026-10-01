import CryptoKit
import Foundation
import Testing

@testable import SukiruCore

/// Support for the real-CLI end-to-end suite: REAL `npx skills` / `gh skill`
/// invocations driven through the built `sukiru-cli` against COPIES of the
/// committed fixtures under `$TMPDIR` (checked-in trees are never mutated).
///
/// Gating: the whole suite is skipped unless `SUKIRU_E2E=1`; gh-networked
/// scenarios additionally require `GH_TOKEN` in the test process env (the
/// token is passed to the CLI child, whose executor injects it into gh
/// commands only).
///
/// Sandboxing proof (defense in depth):
/// - the CLI child receives a FULLY explicit environment (nothing
///   inherited), with `SUKIRU_HOME` pointing at the fixture copy;
/// - `npx`/`gh` on the child's PATH are passthrough wrappers that log their
///   argv, cwd, and env (token presence only) before exec'ing the real
///   binaries — the transcript proves every spawned command and that
///   `HOME` was the sandbox;
/// - a HomeCanary fingerprints the fixture skill names + global lock under
///   the REAL `$HOME` before/after and fails on any change.
enum RealCLIE2ESupport {
    static let enabled = ProcessInfo.processInfo.environment["SUKIRU_E2E"] == "1"

    static let gitHubToken: String? = {
        let token = ProcessInfo.processInfo.environment["GH_TOKEN"] ?? ""
        return token.isEmpty ? nil : token
    }()

    /// The real upstream test repo + skill used by the gh scenarios (same
    /// source the CM fixtures were generated against).
    static let upstreamRepo = "thedavidweng/skills"
    static let upstreamPath = "maintenance/stale-docs-cleanup/SKILL.md"

    /// Real npx runs download the skills package per sandbox HOME and the
    /// gh flows clone the test repo — generous but bounded.
    static let batchTimeout: TimeInterval = 600

    // MARK: - real tool resolution (same trick as Scripts/fixtures/lib.sh)

    struct RealTools {
        let node: String
        let npxCLI: String
        let ghBinary: String
    }

    /// Runs a lookup command inheriting the TEST process environment and
    /// returns its trimmed stdout, or nil on failure.
    static func capture(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let trimmed =
            String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Resolves the real node + npm's npx-cli.js (mise-managed layout, with
    /// a PATH fallback) and the real gh. Fails loudly when SUKIRU_E2E=1 was
    /// set without the toolchain present (mirrors generate.sh --check).
    static func resolveTools() throws -> RealTools {
        let ghBinary = try #require(
            capture("/usr/bin/which", ["gh"]),
            "SUKIRU_E2E=1 but no real `gh` is on the test process PATH")
        var node = capture("/usr/bin/which", ["mise"]).flatMap { capture($0, ["which", "node"]) }
        if node == nil {
            node = capture("/usr/bin/which", ["node"])
        }
        let resolvedNode = try #require(
            node, "SUKIRU_E2E=1 but no real `node` found (mise or PATH)")
        let npxCLI = URL(fileURLWithPath: resolvedNode)
            .deletingLastPathComponent()
            .appendingPathComponent("../lib/node_modules/npm/bin/npx-cli.js")
            .standardizedFileURL.path
        try #require(
            FileManager.default.fileExists(atPath: npxCLI),
            "npx-cli.js not found next to node at \(npxCLI)")
        return RealTools(node: resolvedNode, npxCLI: npxCLI, ghBinary: ghBinary)
    }

    /// Installs `npx`/`gh` passthrough wrappers into `tree/bin`: each logs
    /// `argv|cwd` to the transcript and its env (token PRESENCE only) to a
    /// per-tool dump, then execs the real binary. Returns the bin path to
    /// prepend to the CLI child's PATH.
    static func installToolWrappers(_ tools: RealTools, into tree: TempTree) throws -> String {
        let logDir = try tree.dir("tool-log")
        let envDump = """
              echo "HOME=$HOME"
              echo "PWD=$PWD"
              if [ -n "${GH_TOKEN:-}" ]; then echo "GH_TOKEN=present"; else echo "GH_TOKEN=absent"; fi
            """
        let npxWrapper = """
            #!/bin/sh
            echo "npx|$PWD|$*" >> "\(logDir)/transcript.log"
            {
            \(envDump)
            } >> "\(logDir)/env-npx.log"
            exec "\(tools.node)" "\(tools.npxCLI)" "$@"
            """
        let ghWrapper = """
            #!/bin/sh
            echo "gh|$PWD|$*" >> "\(logDir)/transcript.log"
            {
            \(envDump)
            } >> "\(logDir)/env-gh.log"
            exec "\(tools.ghBinary)" "$@"
            """
        // `node` itself must ALSO be on PATH: the npx-downloaded skills
        // package bin has a `#!/usr/bin/env node` shebang, and the child
        // PATH (bin + /usr/bin:/bin) carries no node otherwise.
        let nodeWrapper = """
            #!/bin/sh
            exec "\(tools.node)" "$@"
            """
        try tree.executable("bin/npx", contents: npxWrapper)
        try tree.executable("bin/gh", contents: ghWrapper)
        try tree.executable("bin/node", contents: nodeWrapper)
        return tree.path + "/bin"
    }

    // MARK: - shared scenario plumbing

    /// A fixture copy ready for real-CLI execution: scan inputs + the PATH
    /// prefix holding the logging wrappers.
    struct PreparedFixture {
        let home: String
        let roots: [String]
        let bin: String
    }

    /// Copies a fixture, resolves the real toolchain, and installs the
    /// logging wrappers.
    static func prepare(_ fixture: String, into tree: TempTree) throws -> PreparedFixture {
        let copy = try BatchExecutionSupport.copyFixture(fixture, into: tree)
        let inputs = FixturePaths.homeAndRoots(atPath: copy)
        let tools = try resolveTools()
        let bin = try installToolWrappers(tools, into: tree)
        return PreparedFixture(home: inputs.home, roots: inputs.roots, bin: bin)
    }

    /// Writes the decisions file and runs a reviewed execution batch
    /// through the real CLI, expecting success. Returns the record.
    static func executeBatch(
        home: String, roots: [String], decisions: [String: Any], tree: TempTree,
        bin: String? = nil, token: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [String: Any] {
        let path = try BatchExecutionSupport.writeDecisions(decisions, into: tree)
        var extra: [String: String] = [:]
        if let token {
            extra["GH_TOKEN"] = token
        }
        let result = try BatchExecutionSupport.runBatch(
            home: home, roots: roots, decisionsPath: path,
            arguments: ["--execute", "--reviewed"],
            path: (bin.map { $0 + ":" } ?? "") + "/usr/bin:/bin",
            extraEnv: extra, timeout: batchTimeout)
        #expect(
            result.exitCode == 0, "stderr: \(BatchExecutionSupport.stderrText(result))",
            sourceLocation: sourceLocation)
        let record = try #require(try result.jsonObject(), sourceLocation: sourceLocation)
        #expect(
            record["batchStatus"] as? String == "succeeded",
            sourceLocation: sourceLocation)
        return record
    }

    static func transcript(_ tree: TempTree) throws -> String {
        let path = tree.path + "/tool-log/transcript.log"
        guard FileManager.default.fileExists(atPath: path) else { return "" }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    static func envDump(_ tree: TempTree, tool: String) throws -> String {
        let path = tree.path + "/tool-log/env-\(tool).log"
        guard FileManager.default.fileExists(atPath: path) else { return "" }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: - scan assertions

    static func findings(
        _ scan: [String: Any], ruleID: String, skill: String
    ) throws -> [[String: Any]] {
        let all = try #require(scan["findings"] as? [[String: Any]])
        return all.filter {
            ($0["ruleID"] as? String) == ruleID && ($0["skillName"] as? String) == skill
        }
    }

    /// `ruleID|workspaceID|skillName` identities — set-comparable across
    /// scans regardless of finding order.
    static func findingIdentities(_ scan: [String: Any]) throws -> Set<String> {
        let all = try #require(scan["findings"] as? [[String: Any]])
        return Set(
            all.map {
                let rule = $0["ruleID"] as? String ?? "?"
                let workspace = $0["workspaceID"] as? String ?? "?"
                let skill = $0["skillName"] as? String ?? "?"
                return "\(rule)|\(workspace)|\(skill)"
            })
    }

    static func skillOwnership(
        _ scan: [String: Any], name: String, scope: String
    ) throws -> String? {
        let skills = try #require(scan["skills"] as? [[String: Any]])
        return skills.first {
            ($0["name"] as? String) == name && ($0["scope"] as? String) == scope
        }?["ownership"] as? String
    }

    /// Byte-identity manifest of a sandbox user scope, excluding Sukiru's
    /// own bookkeeping (snapshots/execution records under Library/...).
    static func userStateManifest(home: String) throws -> [String: String] {
        try TreeChecksum.manifest(root: home).filter { !$0.key.hasPrefix("Library") }
    }

    /// Cross-scope manifest confinement: payload/placement paths all
    /// inside the targeted project; ledgers inside the project plus the
    /// one global lock SnapshotPlan ALWAYS records (read-only rollback
    /// backup — `npx` can write the global lock even from a project cwd).
    static func assertManifestConfined(
        record: [String: Any], home: String, projectRoot: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let snapshotID = try #require(
            record["snapshotID"] as? String, sourceLocation: sourceLocation)
        let manifestPath =
            home + "/Library/Application Support/Sukiru/snapshots/" + snapshotID
            + "/manifest.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        let manifest = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            sourceLocation: sourceLocation)
        let globalLock = home + "/.agents/.skill-lock.json"
        let ledgers = try #require(
            manifest["ledgers"] as? [[String: Any]], sourceLocation: sourceLocation)
        for ledger in ledgers {
            let path = try #require(ledger["path"] as? String)
            #expect(
                path.hasPrefix(projectRoot) || path == globalLock,
                "ledger outside the targeted scope: \(path)",
                sourceLocation: sourceLocation)
        }
        for key in ["placements", "payloads"] {
            let entries = try #require(
                manifest[key] as? [[String: Any]], sourceLocation: sourceLocation)
            for entry in entries {
                let path = try #require(entry["path"] as? String)
                #expect(
                    path.hasPrefix(projectRoot),
                    "\(key) path outside the targeted scope: \(path)",
                    sourceLocation: sourceLocation)
            }
        }
    }

    // MARK: - real-$HOME canary

    /// Fingerprints every path the e2e batches could touch under the REAL
    /// home if sandboxing broke: the pinned CLI's global lock plus the
    /// fixture skill names in the three host dirs our scenarios exercise.
    /// Content-based where the path pre-exists, existence-based otherwise.
    struct HomeCanary {
        let fingerprints: [String: String?]

        init() {
            let home = NSHomeDirectory()
            var paths = [home + "/.agents/.skill-lock.json"]
            for name in ["stale-docs-cleanup", "shared-tool", "orphan"] {
                for hostDir in [".agents/skills", ".claude/skills", ".codex/skills"] {
                    paths.append("\(home)/\(hostDir)/\(name)")
                }
            }
            var fingerprints: [String: String?] = [:]
            for path in paths {
                fingerprints[path] = Self.fingerprint(path)
            }
            self.fingerprints = fingerprints
        }

        func verifyUnchanged(
            sourceLocation: SourceLocation = #_sourceLocation
        ) throws {
            for (path, before) in fingerprints.sorted(by: { $0.key < $1.key }) {
                let after = Self.fingerprint(path)
                #expect(
                    after == before,
                    "REAL $HOME path mutated by a sandboxed batch: \(path)",
                    sourceLocation: sourceLocation)
            }
        }

        private static func fingerprint(_ path: String) -> String? {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return nil
            }
            if isDirectory.boolValue {
                let manifest = (try? TreeChecksum.manifest(root: path)) ?? [:]
                let data =
                    (try? JSONSerialization.data(
                        withJSONObject: manifest, options: [.sortedKeys])) ?? Data()
                return "dir:" + sha256(data)
            }
            let data = FileManager.default.contents(atPath: path) ?? Data()
            return "file:\(data.count):" + sha256(data)
        }

        private static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}
