import Foundation

/// Fetches the raw `SKILL.md` of a search result for pre-install review
/// (prompt-injection risk is inspected, not trusted).
///
/// Read-only by design (the core never writes). The URL is derived from the
/// result's own data:
/// - `gh skill search` results carry the repo-relative `SKILL.md` path, so
///   the raw URL is exact (`https://raw.githubusercontent.com/<repo>/HEAD/<path>`).
/// - skills.sh results carry `source` (owner/repo) and the skill NAME but
///   not the repo-relative path. The skills.sh site resolves these by
///   searching the repo; the closest deterministic read-side approach here
///   is the standard location convention `skills/<name>/SKILL.md`, falling
///   back to `<name>/SKILL.md` and a root `SKILL.md`. This is a preview
///   best-effort — the INSTALL always re-resolves through the official CLI,
///   which is the authoritative discovery (no second discovery rule is
///   invented, ADR-0004).
public struct SkillPreviewFetcher: Sendable {
    private let transport: any MarketplaceTransport

    public init(transport: any MarketplaceTransport) {
        self.transport = transport
    }

    /// The raw SKILL.md URLs to try for a result, in order. A source without
    /// an `owner/repo` slash is a domain publishing skills at
    /// `/.well-known/skills/<name>/` (for example `open.feishu.cn`).
    public static func candidateURLs(for result: SkillSearchResult) -> [URL] {
        guard let repo = result.repo else { return [] }
        if !repo.contains("/") {
            let url = URL(string: "https://\(repo)/.well-known/skills/\(result.name)/SKILL.md")
            return url.map { [$0] } ?? []
        }
        let paths: [String]
        if let path = result.path, !path.isEmpty {
            paths = [path]
        } else {
            paths = [
                "skills/\(result.name)/SKILL.md",
                "\(result.name)/SKILL.md",
                "skills/.curated/\(result.name)/SKILL.md",
                "skills/.experimental/\(result.name)/SKILL.md",
                "SKILL.md"
            ]
        }
        return paths.compactMap { path in
            URL(string: "https://raw.githubusercontent.com/\(repo)/HEAD/\(path)")
        }
    }

    /// Returns the first SKILL.md body that fetches cleanly, or nil when no
    /// candidate resolves (preview unavailable — the row stays installable).
    public func preview(of result: SkillSearchResult) async throws -> String? {
        for url in Self.candidateURLs(for: result) {
            guard let data = try? await transport.fetch(url) else {
                continue
            }
            if !data.isEmpty {
                return String(bytes: data, encoding: .utf8)
            }
        }
        return nil
    }
}
