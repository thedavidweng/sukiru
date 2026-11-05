import Foundation
import SukiruCore

/// Moves one Skill to the other installer's ledger. The destination must be
/// the other ledger: the Skill's current ownership decides the commands.
struct SkillMigrate {
    var selection: SkillSelection
    var output: OutputOptions
    var mutation: MutationOptions
    var installer: InstallerChoice

    func run() throws {
        let environment = try cliEnvironment(roots: selection.inputs.roots)
        let report = try ScanEngine(environment: environment).scan(selection.inputs.mutationRequest)
        let skill = try selection.select(in: report)
        let source: Ownership = installer == .github ? .vercel : .github
        guard skill.ownership == source else {
            throw CLIError(
                "'\(skill.name)' is \(skill.ownership.rawValue)-owned; skills migrate "
                    + "--installer \(installer.rawValue) moves a Skill the other "
                    + "installer's ledger owns")
        }
        let built = CommandBatchBuilder().buildApplicable(
            report: report, decisions: [],
            lifecycle: [LifecycleRequest(skill: skill, action: .migrate)])
        guard built.skipped.isEmpty else { throw CLIError(built.skipped.joined(separator: "\n")) }
        try mutation.apply(built.batch, report: report, environment: environment, output: output)
    }
}
