import ArgumentParser
import Foundation
import SukiruCore

struct Skills: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect and manage Agent Skills through their owners.",
        subcommands: [
            SkillList.self, SkillUpdate.self, SkillUninstall.self, SkillPin.self,
            SkillUnpin.self, SkillRestore.self, SkillAdopt.self, SkillMode.self,
            SkillCheckUpdates.self
        ])
}

struct SkillList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List Skills and ownership.")
    @OptionGroup var inputs: ScopeOptions
    @OptionGroup var output: OutputOptions
    func run() throws {
        let report = try ScanEngine(environment: cliEnvironment(roots: inputs.roots)).scan(
            inputs.request)
        let skills = inputs.skills(in: report)
        try output.render(
            skills,
            lines: skills.map {
                "\($0.name)\t\($0.scope.rawValue)\t\($0.ownership.rawValue)\t"
                    + $0.placements.map(\.path).joined(separator: ", ")
            })
    }
}

struct SkillSelection: ParsableArguments {
    @Argument(help: "Skill name; use --path to disambiguate placements.") var name: String
    @Option(help: "Exact placement path when names occur in multiple projects.") var path: String?
    @OptionGroup var inputs: ScopeOptions

    func select(in report: ScanReport) throws -> Skill {
        let matches = inputs.skills(in: report).filter { skill in
            skill.name == name && (path == nil || skill.placements.contains { $0.path == path })
        }
        guard matches.count == 1, let skill = matches.first else {
            throw CLIError(
                "Expected one Skill named '\(name)'; found \(matches.count). "
                    + "Select --scope, --root, --host, or --path explicitly."
            )
        }
        return skill
    }
}

struct SkillUpdate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update", abstract: "Update one Skill or all eligible Skills.")
    @Argument var name: String?
    @Flag(help: "Update all eligible Skills in scope.") var all = false
    @OptionGroup var inputs: ScopeOptions
    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    mutating func validate() throws {
        guard (name != nil) != all else { throw ValidationError("Choose a Skill name or --all") }
    }
    func run() throws {
        let environment = try cliEnvironment(roots: inputs.roots)
        let report = try ScanEngine(environment: environment).scan(inputs.mutationRequest)
        let selected = inputs.skills(in: report).filter { name == nil || $0.name == name }
        if !all && selected.count != 1 {
            throw CLIError("Select exactly one Skill with --scope/--root/--host")
        }
        var requests: [LifecycleRequest] = []
        for skill in selected {
            let blocker = CommandBatchBuilder.lifecycleBlocker(
                skill: skill, action: .update, capabilities: nil, report: report)
            if let blocker {
                if !all { throw CLIError(blocker.refusal(.update, skill: skill)) }
                emitError(blocker.refusal(.update, skill: skill))
            } else {
                requests.append(LifecycleRequest(skill: skill, action: .update))
            }
        }
        let built = CommandBatchBuilder().buildApplicable(
            report: report, decisions: [], lifecycle: requests)
        if !all && !built.skipped.isEmpty { throw CLIError(built.skipped.joined(separator: "\n")) }
        for skipped in built.skipped { emitError(skipped) }
        try mutation.apply(built.batch, report: report, environment: environment, output: output)
    }
}

protocol SkillLifecycleCommand: ParsableCommand {
    var selection: SkillSelection { get }
    var output: OutputOptions { get }
    var mutation: MutationOptions { get }
    var action: LifecycleAction { get }
    var pinRef: String? { get }
}

extension SkillLifecycleCommand {
    var pinRef: String? { nil }
    func run() throws {
        let environment = try cliEnvironment(roots: selection.inputs.roots)
        let report = try ScanEngine(environment: environment).scan(selection.inputs.mutationRequest)
        let skill = try selection.select(in: report)
        let built = CommandBatchBuilder().buildApplicable(
            report: report, decisions: [],
            lifecycle: [LifecycleRequest(skill: skill, action: action, pinRef: pinRef)])
        guard built.skipped.isEmpty else { throw CLIError(built.skipped.joined(separator: "\n")) }
        try mutation.apply(built.batch, report: report, environment: environment, output: output)
    }
}

struct SkillUninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall", abstract: "Uninstall through the owning manager policy.")
    @Argument var name: String?
    @Flag(help: "Remove every eligible entry from one Agent Host.") var all = false
    @Option(help: "Exact placement path for an individual uninstall.") var path: String?
    @OptionGroup var inputs: ScopeOptions
    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    mutating func validate() throws {
        guard (name != nil) != all else { throw ValidationError("Choose a Skill name or --all") }
        if all && inputs.host == nil { throw ValidationError("--all requires --host") }
        if all && path != nil { throw ValidationError("--path cannot be combined with --all") }
        if all && inputs.scope == .all { inputs.scope = inputs.roots.isEmpty ? .user : .project }
    }

    func run() throws {
        if all {
            try removeFromHost()
            return
        }
        let environment = try cliEnvironment(roots: inputs.roots)
        let report = try ScanEngine(environment: environment).scan(inputs.mutationRequest)
        var selection = SkillSelection()
        selection.name = name!
        selection.path = path
        selection.inputs = inputs
        let skill = try selection.select(in: report)
        let built = CommandBatchBuilder().buildApplicable(
            report: report, decisions: [],
            lifecycle: [LifecycleRequest(skill: skill, action: .uninstall)])
        guard built.skipped.isEmpty else { throw CLIError(built.skipped.joined(separator: "\n")) }
        try mutation.apply(built.batch, report: report, environment: environment, output: output)
    }
}

struct SkillPin: SkillLifecycleCommand {
    static let configuration = CommandConfiguration(
        commandName: "pin", abstract: "Pin a GitHub-owned Skill to a ref.")
    @OptionGroup var selection: SkillSelection
    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    @Option(help: "Git tag, branch, or commit.") var ref: String
    var action: LifecycleAction { .pin }
    var pinRef: String? { ref }
}

struct SkillUnpin: SkillLifecycleCommand {
    static let configuration = CommandConfiguration(
        commandName: "unpin", abstract: "Unpin a GitHub-owned Skill.")
    @OptionGroup var selection: SkillSelection
    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    var action: LifecycleAction { .unpin }
}

struct SkillRestore: SkillLifecycleCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore", abstract: "Restore supported recorded Skill files.")
    @OptionGroup var selection: SkillSelection
    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    var action: LifecycleAction { .restore }
}

struct SkillAdopt: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "adopt",
        abstract: "Explicitly choose an owner and source for an Ownerless Skill.")
    @OptionGroup var selection: SkillSelection
    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    @Option var installer: InstallerChoice
    @Option(help: "Vercel source or GitHub owner/repo.") var source: String
    @Option(help: "Repo-relative Skill path for GitHub adoption.") var skillPath: String?
    mutating func validate() throws {
        if installer == .github && skillPath == nil {
            throw ValidationError("GitHub adoption requires --skill-path")
        }
        if installer == .vercel && skillPath != nil {
            throw ValidationError("--skill-path is only for GitHub adoption")
        }
    }
    func run() throws {
        let environment = try cliEnvironment(roots: selection.inputs.roots)
        let report = try ScanEngine(environment: environment).scan(selection.inputs.mutationRequest)
        let skill = try selection.select(in: report)
        guard
            let entry = FindingID.assignments(for: report.findings).first(where: { entry in
                entry.finding.ruleID == "files-without-lock"
                    && entry.finding.skillName == skill.name
                    && report.workspaces.contains { workspace in
                        workspace.id == entry.finding.workspaceID
                            && skill.placements.contains { $0.path.hasPrefix(workspace.root + "/") }
                    }
            })
        else { throw CLIError("Skill is not an Ownerless adoption candidate") }
        let choice: DecisionChoice
        if installer == .github, let skillPath {
            choice = .adoptSource(repo: source, path: skillPath)
        } else {
            choice = .adoptVercel(source: source)
        }
        let batch = try CommandBatchBuilder().build(
            report: report,
            decisions: [DecisionEntry(findingID: entry.id, action: .adopt, choice: choice)])
        try mutation.apply(batch, report: report, environment: environment, output: output)
    }
}

struct SkillMode: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mode", abstract: "Switch supported placements to links or copies.")
    @OptionGroup var selection: SkillSelection
    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    @Option var mode: PlacementMode
    func run() throws {
        let environment = try cliEnvironment(roots: selection.inputs.roots)
        let report = try ScanEngine(environment: environment).scan(selection.inputs.mutationRequest)
        let batch = try CommandBatchBuilder().buildModeSwitch(
            skill: selection.select(in: report), to: mode, report: report)
        try mutation.apply(batch, report: report, environment: environment, output: output)
    }
}

struct SkillCheckUpdates: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-updates", abstract: "Explicitly ask gh for available Skill updates.")
    @OptionGroup var inputs: ScopeOptions
    @OptionGroup var output: OutputOptions
    func run() throws {
        let environment = try cliEnvironment(roots: inputs.roots)
        let report = try ScanEngine(environment: environment).scan(inputs.request)
        let check = GitHubUpdateChecker(environment: environment).check(inputs.skills(in: report))
        try output.render(
            check.updates.map(\.skill),
            lines: check.updates.map { "Update available: \($0.skill.name)" })
        for failure in check.failures { emitError(failure) }
        if !check.failures.isEmpty { throw ExitCode(1) }
    }
}
