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
