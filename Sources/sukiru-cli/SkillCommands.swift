import Foundation
import SukiruCore

struct SkillList {
    var inputs: ScopeOptions
    var output: OutputOptions
    func run() throws {
        let report = try ScanEngine(environment: cliEnvironment(roots: inputs.roots)).scan(
            inputs.request)
        let skills = inputs.skills(in: report)
        try output.render(
            skills,
            lines: skills.map {
                ($0.packageQualifiedName.map { $0 + "\t" } ?? "")
                    + "\($0.name)\t\($0.scope.rawValue)\t\($0.ownership.rawValue)\t"
                    + $0.placements.map(\.path).joined(separator: ", ")
            })
    }
}

struct SkillSelection {
    var name: String
    var path: String?
    var inputs: ScopeOptions

    func select(in report: ScanReport) throws -> Skill {
        let matches = inputs.skills(in: report).filter { skill in
            (skill.packageQualifiedName == name || skill.name == name)
                && (path == nil || skill.placements.contains { $0.path == path })
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

struct SkillUpdate {
    var name: String?
    var all = false
    var inputs: ScopeOptions
    var output: OutputOptions
    var mutation: MutationOptions
    mutating func validate() throws {
        guard (name != nil) != all else { throw CLIUsageError("Choose a Skill name or --all") }
    }
    func run() throws {
        let environment = try cliEnvironment(roots: inputs.roots)
        let report = try ScanEngine(environment: environment).scan(inputs.mutationRequest)
        let selected = inputs.skills(in: report).filter {
            name == nil || $0.name == name || $0.packageQualifiedName == name
        }
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

protocol SkillLifecycleCommand {
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

struct SkillUninstall {
    var name: String?
    var all = false
    var path: String?
    var inputs: ScopeOptions
    var output: OutputOptions
    var mutation: MutationOptions
    mutating func validate() throws {
        guard (name != nil) != all else { throw CLIUsageError("Choose a Skill name or --all") }
        if all && inputs.host == nil { throw CLIUsageError("--all requires --host") }
        if all && path != nil { throw CLIUsageError("--path cannot be combined with --all") }
        if all && inputs.scope == .all { inputs.scope = inputs.roots.isEmpty ? .user : .project }
    }

    func run() throws {
        if all {
            try removeFromHost()
            return
        }
        let environment = try cliEnvironment(roots: inputs.roots)
        let report = try ScanEngine(environment: environment).scan(inputs.mutationRequest)
        let selection = SkillSelection(name: name!, path: path, inputs: inputs)
        let skill = try selection.select(in: report)
        let built = CommandBatchBuilder().buildApplicable(
            report: report, decisions: [],
            lifecycle: [LifecycleRequest(skill: skill, action: .uninstall)])
        guard built.skipped.isEmpty else { throw CLIError(built.skipped.joined(separator: "\n")) }
        try mutation.apply(built.batch, report: report, environment: environment, output: output)
    }
}

struct SkillPin: SkillLifecycleCommand {
    var selection: SkillSelection
    var output: OutputOptions
    var mutation: MutationOptions
    var ref: String
    var action: LifecycleAction { .pin }
    var pinRef: String? { ref }
}

struct SkillUnpin: SkillLifecycleCommand {
    var selection: SkillSelection
    var output: OutputOptions
    var mutation: MutationOptions
    var action: LifecycleAction { .unpin }
}

struct SkillRestore: SkillLifecycleCommand {
    var selection: SkillSelection
    var output: OutputOptions
    var mutation: MutationOptions
    var action: LifecycleAction { .restore }
}

struct SkillAdopt {
    var selection: SkillSelection
    var output: OutputOptions
    var mutation: MutationOptions
    var installer: InstallerChoice
    var source: String
    var skillPath: String?
    mutating func validate() throws {
        if installer == .github && skillPath == nil {
            throw CLIUsageError("GitHub adoption requires --skill-path")
        }
        if installer == .vercel && skillPath != nil {
            throw CLIUsageError("--skill-path is only for GitHub adoption")
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

struct SkillMode {
    var selection: SkillSelection
    var output: OutputOptions
    var mutation: MutationOptions
    var mode: PlacementMode
    func run() throws {
        let environment = try cliEnvironment(roots: selection.inputs.roots)
        let report = try ScanEngine(environment: environment).scan(selection.inputs.mutationRequest)
        let batch = try CommandBatchBuilder().buildModeSwitch(
            skill: selection.select(in: report), to: mode, report: report)
        try mutation.apply(batch, report: report, environment: environment, output: output)
    }
}

struct SkillCheckUpdates {
    var inputs: ScopeOptions
    var output: OutputOptions
    func run() throws {
        let environment = try cliEnvironment(roots: inputs.roots)
        let report = try ScanEngine(environment: environment).scan(inputs.request)
        let check = GitHubUpdateChecker(environment: environment).check(inputs.skills(in: report))
        try output.render(
            check.updates.map(\.skill),
            lines: check.updates.map { "Update available: \($0.skill.name)" })
        for failure in check.failures { emitError(failure) }
        if !check.failures.isEmpty { throw CLIExit(1) }
    }
}

extension CLI {
    static let skillCommands: [CLICommand] = [
        CLICommand(
            path: "skills", abstract: "Inspect and manage Agent Skills through their owners.",
            options: []),
        CLICommand(
            path: "skills list", abstract: "List Skills and ownership.",
            options: scopeOptions + outputOptions
        ) { arguments in
            let command = SkillList(
                inputs: try ScopeOptions(arguments), output: OutputOptions(arguments))
            try command.run()
        },
        CLICommand(
            path: "skills update", abstract: "Update one Skill or all eligible Skills.",
            options: [
                CLIOption("all", takesValue: false, help: "Update all eligible Skills in scope.")
            ] + scopeOptions + outputOptions + mutationOptions,
            argument: CLIPositional(name: "name", required: false, help: "")
        ) { arguments in
            var command = SkillUpdate(
                name: arguments.positional, all: arguments.flag("all"),
                inputs: try ScopeOptions(arguments), output: OutputOptions(arguments),
                mutation: try MutationOptions(arguments))
            try command.validate()
            try command.run()
        },
        CLICommand(
            path: "skills uninstall", abstract: "Uninstall through the owning manager policy.",
            options: [
                CLIOption(
                    "all", takesValue: false,
                    help: "Remove every eligible entry from one Agent Host."),
                CLIOption(
                    "path", takesValue: true,
                    help: "Exact placement path for an individual uninstall.")
            ] + scopeOptions + outputOptions + mutationOptions,
            argument: CLIPositional(name: "name", required: false, help: "")
        ) { arguments in
            var command = SkillUninstall(
                name: arguments.positional, all: arguments.flag("all"),
                path: arguments.string("path"), inputs: try ScopeOptions(arguments),
                output: OutputOptions(arguments), mutation: try MutationOptions(arguments))
            try command.validate()
            try command.run()
        },
        CLICommand(
            path: "skills pin", abstract: "Pin a GitHub-owned Skill to a ref.",
            options: selectionOptions + outputOptions + mutationOptions + [
                CLIOption(
                    "ref", takesValue: true, help: "Git tag, branch, or commit.", required: true)
            ],
            argument: CLIPositional(
                name: "name", required: true,
                help: "Skill name; use --path to disambiguate placements.")
        ) { arguments in
            let command = SkillPin(
                selection: try SkillSelection(arguments), output: OutputOptions(arguments),
                mutation: try MutationOptions(arguments), ref: try arguments.required("ref"))
            try command.run()
        },
        CLICommand(
            path: "skills unpin", abstract: "Unpin a GitHub-owned Skill.",
            options: selectionOptions + outputOptions + mutationOptions,
            argument: CLIPositional(
                name: "name", required: true,
                help: "Skill name; use --path to disambiguate placements.")
        ) { arguments in
            let command = SkillUnpin(
                selection: try SkillSelection(arguments), output: OutputOptions(arguments),
                mutation: try MutationOptions(arguments))
            try command.run()
        },
        CLICommand(
            path: "skills restore", abstract: "Restore supported recorded Skill files.",
            options: selectionOptions + outputOptions + mutationOptions,
            argument: CLIPositional(
                name: "name", required: true,
                help: "Skill name; use --path to disambiguate placements.")
        ) { arguments in
            let command = SkillRestore(
                selection: try SkillSelection(arguments), output: OutputOptions(arguments),
                mutation: try MutationOptions(arguments))
            try command.run()
        },
        CLICommand(
            path: "skills adopt",
            abstract: "Explicitly choose an owner and source for an Ownerless Skill.",
            options: selectionOptions + outputOptions + mutationOptions + [
                CLIOption("installer", takesValue: true, help: "", required: true),
                CLIOption(
                    "source", takesValue: true, help: "Vercel source or GitHub owner/repo.",
                    required: true),
                CLIOption(
                    "skill-path", takesValue: true,
                    help: "Repo-relative Skill path for GitHub adoption.")
            ],
            argument: CLIPositional(
                name: "name", required: true,
                help: "Skill name; use --path to disambiguate placements.")
        ) { arguments in
            var command = SkillAdopt(
                selection: try SkillSelection(arguments), output: OutputOptions(arguments),
                mutation: try MutationOptions(arguments),
                installer: try arguments.enumeration("installer"),
                source: try arguments.required("source"), skillPath: arguments.string("skill-path"))
            try command.validate()
            try command.run()
        },
        CLICommand(
            path: "skills mode", abstract: "Switch supported placements to links or copies.",
            options: selectionOptions + outputOptions + mutationOptions + [
                CLIOption("mode", takesValue: true, help: "", required: true)
            ],
            argument: CLIPositional(
                name: "name", required: true,
                help: "Skill name; use --path to disambiguate placements.")
        ) { arguments in
            let command = SkillMode(
                selection: try SkillSelection(arguments), output: OutputOptions(arguments),
                mutation: try MutationOptions(arguments), mode: try arguments.enumeration("mode"))
            try command.run()
        },
        CLICommand(
            path: "skills check-updates",
            abstract: "Explicitly ask gh for available Skill updates.",
            options: scopeOptions + outputOptions
        ) { arguments in
            let command = SkillCheckUpdates(
                inputs: try ScopeOptions(arguments), output: OutputOptions(arguments))
            try command.run()
        }
    ]
}
