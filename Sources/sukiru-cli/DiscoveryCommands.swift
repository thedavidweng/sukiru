import Foundation
import SukiruCore

struct Search {
    var query: String
    var backend: SkillSearchResult.Backend = .skillsDotSh
    var owner: String?
    var limit = 20
    var output: OutputOptions
    mutating func validate() throws {
        guard limit > 0 else { throw CLIUsageError("--limit must be positive") }
        guard SkillSearchRequest.parse(query: query, owner: owner, backend: backend) != nil else {
            throw CLIUsageError("Search needs at least two characters or an owner filter")
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

struct Install {
    var source: String
    var skills: [String] = []
    var installer: InstallerChoice
    var inputs: ScopeOptions
    var output: OutputOptions
    var mutation: MutationOptions
    var copy = false
    var pin: String?
    mutating func validate() throws {
        guard !skills.isEmpty else { throw CLIUsageError("Select at least one --skill") }
        if installer == .github && copy {
            throw CLIUsageError("--copy is only supported by Vercel")
        }
        if installer == .vercel && pin != nil {
            throw CLIUsageError("--pin is only supported by GitHub")
        }
        if let pin, !LifecycleRequest.isValidPinRef(pin) {
            throw CLIUsageError("Invalid pin ref")
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

extension CLI {
    static let discoveryCommands: [CLICommand] = [
        CLICommand(
            path: "search", abstract: "Search existing discovery backends (explicit remote read).",
            options: [
                CLIOption("backend", takesValue: true, help: ""),
                CLIOption("owner", takesValue: true, help: "GitHub owner filter."),
                CLIOption("limit", takesValue: true, help: "Maximum results.")
            ] + outputOptions,
            argument: CLIPositional(name: "query", required: true, help: "Search text.")
        ) { arguments in
            var command = Search(
                query: try arguments.requiredPositional(),
                backend: try arguments.enumeration("backend", default: .skillsDotSh),
                owner: arguments.string("owner"),
                limit: arguments.integer("limit", default: 20),
                output: OutputOptions(arguments))
            try command.validate()
            try await command.run()
        },
        CLICommand(
            path: "install",
            abstract: "Plan or install explicitly addressed Skills through an official installer.",
            options: [
                CLIOption(
                    "skill", takesValue: true,
                    help: "Skill name or exact GitHub Skill path; repeatable.", repeating: true),
                CLIOption("installer", takesValue: true, help: "", required: true)
            ] + scopeOptions
                + outputOptions
                + mutationOptions + [
                    CLIOption("copy", takesValue: false, help: "Install standalone Vercel copies."),
                    CLIOption("pin", takesValue: true, help: "GitHub pin ref.")
                ],
            argument: CLIPositional(
                name: "source", required: true, help: "GitHub owner/repo or repository URL.")
        ) { arguments in
            var command = Install(
                source: try arguments.requiredPositional(), skills: arguments.values("skill"),
                installer: try arguments.enumeration("installer"),
                inputs: try ScopeOptions(arguments), output: OutputOptions(arguments),
                mutation: try MutationOptions(arguments), copy: arguments.flag("copy"),
                pin: arguments.string("pin"))
            try command.validate()
            try command.run()
        }
    ]
}
