import Foundation

/// The `gh skill search` client (github backend).
///
/// `gh skill search <query> --json description,namespace,path,repo,skillName,stars
/// -L <limit>` is a local subprocess (needs gh ≥ 2.90.0) that queries the
/// GitHub Code Search API. The `path` it returns is the repo-relative
/// `SKILL.md` path, which makes preview precise.
///
/// The transport is the existing `CommandRunning` seam, so tests stub the
/// subprocess outcome exactly like the capability detectors do.
public struct GitHubSkillSearchClient: Sendable {
    public struct SearchResult: Decodable, Sendable {
        public let description: String?
        public let namespace: String
        public let path: String
        public let repo: String
        public let skillName: String
        public let stars: Int?
    }

    private let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    /// Runs `gh skill search`. `limit` maps to `-L`, `owner` to `--owner`.
    /// Non-zero exit or unparseable JSON surfaces as a marketplace failure
    /// (never a crash).
    public func search(
        query: String, owner: String? = nil, limit: Int = 25
    ) async throws -> [SkillSearchResult] {
        let jsonFields = "description,namespace,path,repo,skillName,stars"
        var args = [
            "skill", "search", query,
            "--json", jsonFields,
            "-L", String(limit)
        ]
        if let owner {
            args += ["--owner", owner]
        }
        guard let outcome = runner.run("gh", args) else {
            throw MarketplaceError.transport("gh executable not found")
        }
        guard outcome.exitCode == 0 else {
            let stderr = outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MarketplaceError.transport(
                stderr.isEmpty ? "gh skill search exited \(outcome.exitCode)" : stderr)
        }
        let decoded: [SearchResult]
        do {
            decoded = try JSONDecoder().decode([SearchResult].self, from: Data(outcome.stdout.utf8))
        } catch {
            throw MarketplaceError.malformed(String(describing: error))
        }
        return decoded.map { result in
            SkillSearchResult(
                name: result.skillName,
                repo: result.repo,
                path: result.path,
                description: result.description,
                installs: nil,
                stars: result.stars ?? 0,
                backend: .github)
        }
    }
}
