import Foundation

@testable import SukiruCore

/// Shared builders for the OwnershipResolver test suites: minimal SKILL.md
/// bodies, lock files, and the scan entry point over TempTree.
enum OwnershipBuilders {
    /// A minimal valid SKILL.md with no provenance.
    static func skillMD(_ name: String) -> String {
        """
        ---
        name: \(name)
        description: The \(name) skill.
        ---
        Body.
        """
    }

    /// A SKILL.md carrying gh provenance; `pinned: nil` OMITS the key
    /// entirely (the absent-key tri-state case).
    static func ghSkillMD(_ name: String, repo: String, pinned: Bool? = nil) -> String {
        let pinnedLine = pinned == nil ? "" : "  github-pinned: \(pinned!)\n"
        return """
            ---
            name: \(name)
            description: The \(name) skill.
            metadata:
              github-repo: \(repo)
              github-path: tools/\(name)/SKILL.md
              github-ref: refs/heads/main
              github-tree-sha: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            \(pinnedLine)---
            Body.
            """
    }

    /// A global v3 lock claiming each of `names` with full entry fields.
    static func globalLock(_ names: [String]) -> String {
        let entries = names.map { name in
            """
                    "\(name)": {
                      "source": "thedavidweng/skills",
                      "sourceType": "github",
                      "sourceUrl": "https://github.com/thedavidweng/skills.git",
                      "skillPath": ".agents/skills/\(name)/SKILL.md",
                      "skillFolderHash": "9999999999999999999999999999999999999999",
                      "installedAt": "2026-06-15T23:27:24.742Z",
                      "updatedAt": "2026-06-15T23:27:24.742Z"
                    }
            """
        }.joined(separator: ",\n")
        return """
            {
              "version": 3,
              "skills": {
            \(entries)
              },
              "dismissed": {}
            }
            """
    }

    /// A project v1 lock claiming `name` with a fixed computedHash.
    static func projectLock(_ name: String) -> String {
        """
        {
          "version": 1,
          "skills": {
            "\(name)": {
              "source": "thedavidweng/skills",
              "sourceType": "github",
              "sourceUrl": "https://github.com/thedavidweng/skills.git",
              "ref": "refs/heads/main",
              "skillPath": ".agents/skills/\(name)/SKILL.md",
              "computedHash": "45c1c9bb9a52d7c1e4380406e2b9d2e9ce61a665ff292c3373b19e9463a43a19"
            }
          }
        }
        """
    }

    /// Scans a TempTree home plus optional project roots.
    static func scan(home: TempTree, projectRoots: [TempTree] = []) throws -> ScanReport {
        var vars = ["SUKIRU_HOME": home.path]
        if !projectRoots.isEmpty {
            vars["SUKIRU_ROOTS"] = projectRoots.map(\.path).joined(separator: ":")
        }
        let environment = SukiruEnvironment(reader: DictionaryEnvironmentReader(vars))
        return try ScanEngine(environment: environment).scan(ScanRequest())
    }

    /// Scans a checked-in fixture that IS the fake home.
    static func scan(fixture name: String) throws -> ScanReport {
        let vars = ["SUKIRU_HOME": FixturePaths.tree(name)]
        let environment = SukiruEnvironment(reader: DictionaryEnvironmentReader(vars))
        return try ScanEngine(environment: environment).scan(ScanRequest())
    }

    /// Scans a CM-style two-part fixture: fake home under `.home`, project
    /// roots as named subdirectories passed via SUKIRU_ROOTS.
    static func scanSplitFixture(_ name: String, roots: [String] = ["proj"]) throws -> ScanReport {
        let tree = FixturePaths.tree(name)
        var vars = ["SUKIRU_HOME": tree + "/.home"]
        vars["SUKIRU_ROOTS"] = roots.map { tree + "/" + $0 }.joined(separator: ":")
        let environment = SukiruEnvironment(reader: DictionaryEnvironmentReader(vars))
        return try ScanEngine(environment: environment).scan(ScanRequest())
    }
}
