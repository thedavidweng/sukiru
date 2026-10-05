import Foundation

extension BatchCommandFactory {
    static func vercelRemove(
        names: [String], agents: [String], scope: Scope, atRisk: [AtRiskSkill],
        intent: String, consequence: CommandConsequence? = nil,
        workingDirectory: String? = nil, captureRoots: [String]? = nil,
        sharedCopyWarning: String? = nil
    ) -> BatchCommand {
        var argv = ["npx", "skills", "remove"] + names
        if !agents.isEmpty { argv += ["-a"] + agents }
        if scope == .user {
            argv.append("-g")
        } else if !agents.isEmpty {
            argv.append("-p")
        }
        argv.append("-y")
        return BatchCommand(
            argv: argv,
            displayString: BatchCommand.display(for: argv),
            owningCLI: .vercel,
            intent: intent,
            dangerFlags: [.dangerousDeletion],
            warning: [
                dangerousDeletionWarning(name: names.joined(separator: ", "), atRisk: atRisk),
                sharedCopyWarning
            ]
            .compactMap { $0 }.joined(separator: " "),
            atRiskSkills: atRisk,
            consequence: consequence,
            workingDirectory: workingDirectory,
            captureRoots: captureRoots
        )
    }

}
