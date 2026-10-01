import Foundation
import Testing

@testable import SukiruCore

/// The cross-cutting scan guarantees, exercised at
/// the engine seam: determinism (byte-identical repeats, root-order
/// independence), SUKIRU_HOME hermeticity, strict read-only behavior, and
/// whole-report scope partitioning. The CLI-level twins of these tests live
/// in `CLIIntegrationTests`.
@Suite("Scan guarantees (engine level)")
struct ScanGuaranteeTests {
    private func scan(
        home: String,
        roots: [String] = [],
        scope: Scope = .all
    ) throws -> ScanReport {
        var vars = ["SUKIRU_HOME": home]
        if !roots.isEmpty {
            vars["SUKIRU_ROOTS"] = roots.joined(separator: ":")
        }
        let environment = SukiruEnvironment(reader: DictionaryEnvironmentReader(vars))
        return try ScanEngine(environment: environment).scan(ScanRequest(scope: scope))
    }

    /// Canonical, order-independent encoding of report collections so union
    /// properties can be compared as sets.
    private func canonicalSet<Value: Encodable>(_ values: [Value]) throws -> Set<String> {
        var encoded = Set<String>()
        for value in values {
            let data = try JSONEncoder.sukiruCanonical.encode(value)
            encoded.insert(String(bytes: data, encoding: .utf8) ?? "")
        }
        return encoded
    }

    @Test("Repeat scans of the same tree are byte-identical")
    func repeatScansByteIdentical() throws {
        for fixture in ["scope-isolation", "FIX-DUPLICATES", "clean-copy-mode"] {
            let inputs = FixturePaths.homeAndRoots(fixture)
            let first = try scan(home: inputs.home, roots: inputs.roots)
            let second = try scan(home: inputs.home, roots: inputs.roots)
            #expect(
                try first.jsonData() == second.jsonData(),
                "repeat scan of \(fixture) diverged"
            )
        }
    }

    @Test("SUKIRU_ROOTS order does not change a single byte")
    func rootOrderIndependence() throws {
        // THREE roots (a:b:c vs c:a:b): own-per-project's
        // p1/p2 plus clean-copy-mode's proj as the third.
        let inputs = FixturePaths.homeAndRoots("own-per-project")
        let roots = inputs.roots + [FixturePaths.tree("clean-copy-mode") + "/proj"]
        #expect(roots.count == 3)
        let forward = try scan(home: inputs.home, roots: roots)
        let reversed = try scan(home: inputs.home, roots: roots.reversed())
        #expect(try forward.jsonData() == reversed.jsonData())
    }

    @Test("Every reported path lies under SUKIRU_HOME or SUKIRU_ROOTS")
    func hermeticityPathAudit() throws {
        // Scan a COPY of each fixture under $TMPDIR (outside the real home),
        // so that any leaked real-home path is unambiguous: the checked-in
        // fixtures legitimately live under the developer's home directory.
        for fixture in ["scope-isolation", "clean-copy-mode", "multi-host-inventory"] {
            let sandbox = try TempTree()
            // Canonicalize the sandbox base: macOS temp dirs live under /var,
            // a symlink to /private/var, and the report's realpath-resolved
            // canonicalPath fields use the resolved form.
            let copy = sandbox.canonicalPath + "/" + fixture
            try FileManager.default.copyItem(atPath: FixturePaths.tree(fixture), toPath: copy)
            let inputs = FixturePaths.homeAndRoots(atPath: copy)
            let report = try scan(home: inputs.home, roots: inputs.roots)
            let json = try JSONSerialization.jsonObject(with: report.jsonData())
            let paths = ReportPathAudit.absolutePaths(in: json)
            let allowed = [inputs.home] + inputs.roots
            let violations = ReportPathAudit.pathsOutside(paths, allowedRoots: allowed)
            #expect(
                violations.isEmpty,
                "fixture \(fixture) leaked paths outside the sandbox: \(violations)"
            )
            // The real home holds real skill installations on this machine;
            // none of its paths may surface while SUKIRU_HOME is set.
            let realHome = NSHomeDirectory()
            #expect(
                !paths.contains { $0 == realHome || $0.hasPrefix(realHome + "/") },
                "fixture \(fixture) leaked real-home paths"
            )
        }
    }

    @Test("Scanning a tree leaves it byte-identical (read-only)")
    func scanIsReadOnly() throws {
        for fixture in ["own-per-project", "FIX-CLEAN", "alias-link-mode", "FIX-GARBAGE"] {
            let inputs = FixturePaths.homeAndRoots(fixture)
            let root = FixturePaths.tree(fixture)
            let before = try TreeChecksum.manifest(root: root)
            _ = try scan(home: inputs.home, roots: inputs.roots)
            let after = try TreeChecksum.manifest(root: root)
            #expect(before == after, "scan mutated fixture \(fixture)")
        }
    }

    @Test("--scope partitions workspaces, skills, findings, issues")
    func scopePartitionsWholeReport() throws {
        let inputs = FixturePaths.homeAndRoots("scope-isolation")
        let all = try scan(home: inputs.home, roots: inputs.roots)
        let userOnly = try scan(home: inputs.home, roots: inputs.roots, scope: .user)
        let projectOnly = try scan(home: inputs.home, roots: inputs.roots, scope: .project)

        // Workspaces partition by kind.
        #expect(!all.workspaces.isEmpty)
        #expect(userOnly.workspaces.allSatisfy { $0.kind == .user })
        #expect(projectOnly.workspaces.allSatisfy { $0.kind == .project })
        #expect(all.workspaces == userOnly.workspaces + projectOnly.workspaces)

        // Skills partition by scope.
        #expect(userOnly.skills.allSatisfy { $0.scope == .user })
        #expect(projectOnly.skills.allSatisfy { $0.scope == .project })

        // Findings anchor only to workspace ids of their own scope.
        let userWorkspaceIDs = Set(userOnly.workspaces.map(\.id))
        let projectWorkspaceIDs = Set(projectOnly.workspaces.map(\.id))
        #expect(userOnly.findings.allSatisfy { userWorkspaceIDs.contains($0.workspaceID) })
        #expect(projectOnly.findings.allSatisfy { projectWorkspaceIDs.contains($0.workspaceID) })

        // Union property: filtered reports reassemble the full report.
        #expect(try canonicalSet(all.skills) == canonicalSet(userOnly.skills + projectOnly.skills))
        #expect(
            try canonicalSet(all.findings) == canonicalSet(userOnly.findings + projectOnly.findings)
        )
        #expect(try canonicalSet(all.issues) == canonicalSet(userOnly.issues + projectOnly.issues))

        // The fixture's per-scope orphans prove no cross-scope bleed:
        // user-orphan only in user scope, proj-orphan only in project scope.
        #expect(userOnly.skills.map(\.name).contains("user-orphan"))
        #expect(!projectOnly.skills.map(\.name).contains("user-orphan"))
        #expect(projectOnly.skills.map(\.name).contains("proj-orphan"))
        #expect(!userOnly.skills.map(\.name).contains("proj-orphan"))
    }
}

extension JSONEncoder {
    /// Sorted-key encoder for set-canonicalization in tests.
    fileprivate static var sukiruCanonical: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
