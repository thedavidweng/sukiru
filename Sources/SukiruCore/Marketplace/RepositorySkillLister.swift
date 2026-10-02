import Foundation

/// One skill an official installer found in a source repository.
public struct RepositorySkill: Equatable, Sendable, Identifiable {
    /// The name exactly as the installer listed it. It is passed back to the
    /// same installer verbatim, because the two CLIs discover and name the
    /// skills of one repository differently (npx lists frontmatter names,
    /// gh lists directory names with convention tags such as `[root] `).
    public let name: String
    public let description: String?

    public var id: String { name }

    public init(name: String, description: String?) {
        self.name = name
        self.description = description
    }
}

/// Lists the skills in a repository by asking the installer that will
/// install them, so Sukiru never applies a discovery rule of its own.
///
/// Both listings are read-only (probe-verified: no files appear in `$HOME`
/// or the working directory):
/// - vercel: `npx --offline skills add <owner/repo> -l` (skills@1.7.0
///   refuses `--json` with `-l`, so the human listing is parsed).
///   `--offline` keeps npx from fetching the CLI itself.
/// - github: `gh skill install <owner/repo>` without a skill name, which
///   prints `name<TAB>description` rows when stdout is not a terminal
///   (gh 2.102.0).
public struct RepositorySkillLister: Sendable {
    /// Listing clones or walks the repository, far slower than a probe.
    static let timeout: TimeInterval = 180

    private let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    public init(environment: SukiruEnvironment) {
        self.init(runner: SystemCommandRunner(environment: environment, timeout: Self.timeout))
    }

    /// The skills `installer` finds in `repo` (an owner/repo slug). Throws
    /// `MarketplaceError.transport` with the CLI's diagnostic on failure.
    public func skills(in repo: String, installer: InstallerChoice) throws -> [RepositorySkill] {
        let arguments = Self.arguments(repo: repo, installer: installer)
        guard let outcome = runner.run(installer.executable, arguments) else {
            throw MarketplaceError.transport(
                "\(installer.executable) could not be started or timed out")
        }
        guard outcome.exitCode == 0 else {
            throw MarketplaceError.transport(Self.diagnostic(outcome, installer: installer))
        }
        switch installer {
        case .vercel:
            return Self.parseVercelListing(outcome.stdout)
        case .github:
            return Self.parseGitHubListing(outcome.stdout)
        }
    }

    static func arguments(repo: String, installer: InstallerChoice) -> [String] {
        switch installer {
        case .vercel:
            return ["--offline", "skills", "add", repo, "-l"]
        case .github:
            return ["skill", "install", repo]
        }
    }

    /// Parses the `Available Skills` block of `npx skills add -l`: each
    /// skill is a `│    <name>` line followed by a `│      <description>`
    /// line; plugin group titles are unprefixed lines and are skipped.
    static func parseVercelListing(_ output: String) -> [RepositorySkill] {
        var skills: [RepositorySkill] = []
        var inListing = false
        var pendingName: String?
        for line in stripANSI(output).components(separatedBy: "\n") {
            if !inListing {
                inListing = line.hasSuffix("Available Skills")
                continue
            }
            guard let body = barBody(line) else {
                if line.hasPrefix("└") { break }
                continue
            }
            if body.hasPrefix("    "), let name = pendingName {
                let description = body.trimmingCharacters(in: .whitespaces)
                skills.append(
                    RepositorySkill(
                        name: name, description: description.isEmpty ? nil : description))
                pendingName = nil
            } else if body.hasPrefix("  "), body.dropFirst(2).first?.isWhitespace == false {
                if let name = pendingName {
                    skills.append(RepositorySkill(name: name, description: nil))
                }
                pendingName = body.trimmingCharacters(in: .whitespaces)
            }
        }
        if let name = pendingName {
            skills.append(RepositorySkill(name: name, description: nil))
        }
        return skills
    }

    /// Parses the piped `gh skill install <repo>` table: one
    /// `name<TAB>description` row per skill. Lines without a tab continue a
    /// multi-line description and are dropped.
    static func parseGitHubListing(_ output: String) -> [RepositorySkill] {
        output.components(separatedBy: "\n").compactMap { line in
            guard let tab = line.firstIndex(of: "\t") else { return nil }
            let name = line[..<tab].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            let description = line[line.index(after: tab)...]
                .trimmingCharacters(in: .whitespaces)
            return RepositorySkill(
                name: name, description: description.isEmpty ? nil : description)
        }
    }

    /// The text after a clack `│  ` gutter (unicode or ASCII fallback).
    private static func barBody(_ line: String) -> Substring? {
        for bar in ["│  ", "|  "] where line.hasPrefix(bar) {
            return line.dropFirst(bar.count)
        }
        return nil
    }

    private static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    /// What the CLI said went wrong. gh reports on stderr. The skills CLI
    /// reports on stdout (stderr holds only npm notices): a `■  <failure>`
    /// line, then the reason in the gutter below it.
    static func diagnostic(_ outcome: ProcessOutcome, installer: InstallerChoice) -> String {
        var lines = stripANSI(installer == .github ? outcome.stderr : outcome.stdout)
            .components(separatedBy: "\n")
        let failure = installer == .vercel ? lines.firstIndex { $0.hasPrefix("■") } : nil
        if let failure {
            lines = Array(lines[failure...])
        }
        let gutter = CharacterSet(charactersIn: "│■└ ")
        let text = lines.map { $0.trimmingCharacters(in: gutter) }.filter { !$0.isEmpty }
        let relevant = failure == nil ? text.suffix(3) : text.prefix(2)
        guard !relevant.isEmpty else {
            return "\(installer.executable) exited \(outcome.exitCode)"
        }
        return relevant.joined(separator: "\n")
    }
}
