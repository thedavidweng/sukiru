import ArgumentParser
import Foundation
import SukiruCore

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Search existing discovery backends (explicit remote read).")
    @Argument(help: "Search text.") var query: String
    @Option var backend: SkillSearchResult.Backend = .skillsDotSh
    @Option(help: "GitHub owner filter.") var owner: String?
    @Option(help: "Maximum results.") var limit = 20
    @OptionGroup var output: OutputOptions
    mutating func validate() throws {
        guard limit > 0 else { throw ValidationError("--limit must be positive") }
        guard SkillSearchRequest.parse(query: query, owner: owner, backend: backend) != nil else {
            throw ValidationError("Search needs at least two characters or an owner filter")
        }
    }
    func run() async throws {
        let environment = try cliEnvironment()
        guard let request = SkillSearchRequest.parse(query: query, owner: owner, backend: backend)
        else {
            throw CLIError("Search query is empty")
        }
        let results: [SkillSearchResult]
        switch backend {
        case .skillsDotSh:
            results = try await SkillsDotShSearchClient(transport: URLSessionMarketplaceTransport())
                .search(
                    query: request.query, owner: request.owner, limit: limit)
        case .github:
            results = try await GitHubSkillSearchClient(
                runner: SystemCommandRunner(environment: environment)
            ).search(
                query: request.query, owner: request.owner, limit: limit)
        }
        try output.render(
            results,
            lines: results.map {
                "\($0.name)\t\($0.repo ?? "unknown source")\t\($0.description ?? "")"
            })
    }
}

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Plan or install explicitly addressed Skills through an official installer.")
    @Argument(help: "GitHub owner/repo or repository URL.") var source: String
    @Option(name: .customLong("skill"), help: "Skill name or exact GitHub Skill path; repeatable.")
    var skills: [String] = []
    @Option var installer: InstallerChoice
    @OptionGroup var inputs: ScopeOptions
    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    @Flag(help: "Install standalone Vercel copies.") var copy = false
    @Option(help: "GitHub pin ref.") var pin: String?
    mutating func validate() throws {
        guard !skills.isEmpty else { throw ValidationError("Select at least one --skill") }
        if installer == .github && copy {
            throw ValidationError("--copy is only supported by Vercel")
        }
        if installer == .vercel && pin != nil {
            throw ValidationError("--pin is only supported by GitHub")
        }
        if let pin, !LifecycleRequest.isValidPinRef(pin) {
            throw ValidationError("Invalid pin ref")
        }
    }
    func run() throws {
        let environment = try cliEnvironment(roots: inputs.roots)
        let target = try inputs.installTarget(environment: environment)
        let report = try ScanEngine(environment: environment).scan(inputs.mutationRequest)
        let ghAgent = inputs.host.flatMap { id in HostTable.hosts.first { $0.id == id }?.ghAgentId }
        if installer == .github && ghAgent == nil {
            throw CLIError("Choose an Agent Host supported by gh skill with --host")
        }
        let batch: CommandBatch
        do {
            batch = try InstallPlanBuilder(report: report).build(
                repo: InstallPlanBuilder.ownerRepo(fromSource: source), skills: skills,
                installer: installer, target: target,
                options: InstallOptions(
                    vercelAgents: inputs.host.map { [$0] } ?? [], ghAgent: ghAgent,
                    ghPinRef: pin, copy: copy))
        } catch let error as InstallPlanError { throw CLIError(error.message) }
        try mutation.apply(batch, report: report, environment: environment, output: output)
    }
}

extension ScopeOptions {
    func installTarget(environment: SukiruEnvironment) throws -> InstallTarget {
        switch scope {
        case .user: return .user
        case .project:
            let selectedRoots = roots.isEmpty ? environment.projectRoots : roots
            guard selectedRoots.count == 1, let root = selectedRoots.first else {
                throw CLIError("Project mutation requires exactly one --root")
            }
            guard FileManager.default.fileExists(atPath: root) else {
                throw CLIError("Project root does not exist: \(root)")
            }
            return .project(root: URL(fileURLWithPath: root).standardizedFileURL.path)
        case .all: throw CLIError("Choose --scope user or --scope project for installation")
        }
    }
}
