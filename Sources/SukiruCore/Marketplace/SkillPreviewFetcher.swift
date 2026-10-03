import Foundation

/// A search result's skill as fetched for pre-install review: its raw
/// `SKILL.md` and, when skills.sh supplied the whole skill, the other files
/// it ships.
public struct SkillPreview: Equatable, Sendable {
    public let skillMD: String
    /// Paths relative to the skill folder, sorted; empty when only the
    /// `SKILL.md` itself was reachable.
    public let files: [String]
    /// The frontmatter `description`, which skills.sh search omits.
    public let description: String?

    public init(skillMD: String, files: [String] = []) {
        self.skillMD = skillMD
        self.files = files
        description = FrontmatterParser.summary(ofSkillMD: skillMD)?.description
    }
}

/// Fetches the raw `SKILL.md` of a search result for pre-install review
/// (prompt-injection risk is inspected, not trusted).
///
/// Read-only by design (the core never writes). Sources, in order:
/// - skills.sh results carry the skill's slug, and
///   `https://skills.sh/api/download/<owner>/<repo>/<slug>` returns the
///   skill's files exactly as `npx skills add` downloads them, wherever the
///   repository nests its skills.
/// - `gh skill search` results carry the repo-relative `SKILL.md` path, so
///   the raw URL is exact (`https://raw.githubusercontent.com/<repo>/HEAD/<path>`).
/// - Otherwise the standard locations are tried: `skills/<name>/SKILL.md`,
///   `<name>/SKILL.md`, and a root `SKILL.md`. This is a preview
///   best-effort — the INSTALL always re-resolves through the official CLI,
///   which is the authoritative discovery (no second discovery rule is
///   invented, ADR-0004).
public struct SkillPreviewFetcher: Sendable {
    private let transport: any MarketplaceTransport

    public init(transport: any MarketplaceTransport) {
        self.transport = transport
    }

    /// The skills.sh download URL for a GitHub-hosted skills.sh result.
    /// Domain sources are not served there; they publish their own files.
    public static func downloadURL(for result: SkillSearchResult) -> URL? {
        guard let slug = result.slug, let repo = result.repo else { return nil }
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let encoded = (parts.map(String.init) + [slug]).compactMap {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"]))
        }
        guard encoded.count == 3 else { return nil }
        return URL(string: "https://skills.sh/api/download/\(encoded.joined(separator: "/"))")
    }

    /// The raw SKILL.md URLs to try for a result, in order. A source without
    /// an `owner/repo` slash is a domain publishing skills at
    /// `/.well-known/skills/<name>/` (for example `open.feishu.cn`).
    public static func candidateURLs(for result: SkillSearchResult) -> [URL] {
        guard let repo = result.repo else { return [] }
        let name = result.slug ?? result.name
        if !repo.contains("/") {
            let url = URL(string: "https://\(repo)/.well-known/skills/\(name)/SKILL.md")
            return url.map { [$0] } ?? []
        }
        let paths: [String]
        if let path = result.path, !path.isEmpty {
            paths = [path]
        } else {
            paths = [
                "skills/\(name)/SKILL.md",
                "\(name)/SKILL.md",
                "skills/.curated/\(name)/SKILL.md",
                "skills/.experimental/\(name)/SKILL.md",
                "SKILL.md"
            ]
        }
        return paths.compactMap { path in
            URL(string: "https://raw.githubusercontent.com/\(repo)/HEAD/\(path)")
        }
    }

    /// The skill for review, or nil when no source resolves (preview
    /// unavailable — the row stays installable).
    public func skill(of result: SkillSearchResult) async -> SkillPreview? {
        if let preview = await download(result) {
            return preview
        }
        for url in Self.candidateURLs(for: result) {
            guard let data = try? await transport.fetch(url), !data.isEmpty,
                let text = String(bytes: data, encoding: .utf8)
            else { continue }
            return SkillPreview(skillMD: text)
        }
        return nil
    }

    private func download(_ result: SkillSearchResult) async -> SkillPreview? {
        guard let url = Self.downloadURL(for: result),
            let data = try? await transport.fetch(url)
        else { return nil }
        return Self.preview(fromDownload: data)
    }

    /// Returns the first SKILL.md body that fetches cleanly, or nil when no
    /// candidate resolves.
    public func preview(of result: SkillSearchResult) async throws -> String? {
        await skill(of: result)?.skillMD
    }

    /// The download body is `{"files": [{"path", "contents"}], "hash"}`;
    /// the skill's own `SKILL.md` is the one at the folder root.
    static func preview(fromDownload data: Data) -> SkillPreview? {
        guard let download = try? JSONDecoder().decode(SkillDownload.self, from: data),
            let skillMD = download.files.first(where: {
                $0.path.caseInsensitiveCompare("SKILL.md") == .orderedSame
            }),
            !skillMD.contents.isEmpty
        else { return nil }
        let others = download.files.map(\.path).filter { $0 != skillMD.path }
        return SkillPreview(
            skillMD: skillMD.contents,
            files: others.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }
}

/// The skills.sh download API body; `hash` is not needed for review.
private struct SkillDownload: Decodable {
    struct File: Decodable {
        let path: String
        let contents: String
    }
    let files: [File]
}
