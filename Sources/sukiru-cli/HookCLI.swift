import ArgumentParser
import Foundation
import SukiruCore

struct Hooks: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Advanced: existing passive hook inventory and explicit cleanup plans.",
        subcommands: [HookInventoryCommand.self, HookPlanCommand.self, HookExecuteCommand.self])
}

struct HookInventoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inventory", abstract: "Read hook sources and passive diagnoses.")
    @OptionGroup var inputs: ScopeOptions
    @OptionGroup var output: OutputOptions
    func run() throws {
        let report = try ScanEngine(environment: cliEnvironment(roots: inputs.roots)).scan(
            inputs.request)
        try output.render(
            report, lines: ["Hook inventory: \(String(describing: report.hookInventory))"])
    }
}

struct HookPlanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan", abstract: "Build cleanup from explicit hook requests.")
    @Option var requests: String
    @OptionGroup var inputs: ScopeOptions
    @OptionGroup var output: OutputOptions
    func run() throws {
        let environment = try cliEnvironment(roots: inputs.roots)
        let plugins = PluginInventoryReader(environment: environment).read(inputs.request)
        let inventory = HookInventoryReader(environment: environment).read(
            inputs.request, plugins: plugins)
        let plan = try HookCleanupPlanner(environment: environment).plan(
            requests: readJSON([HookCleanupRequest].self, from: requests), inventory: inventory)
        try output.render(plan, lines: plan.batch.reviewLines + plan.instructions)
    }
}

struct HookExecuteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "execute",
        abstract: "Execute a reviewed hook plan with danger acknowledgement.")
    @Option var plan: String
    @OptionGroup var inputs: ScopeOptions
    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    func run() throws {
        let environment = try cliEnvironment(roots: inputs.roots)
        let cleanup = try readJSON(HookCleanupPlan.self, from: plan)
        guard cleanup.instructions.isEmpty, !cleanup.batch.commands.isEmpty else {
            throw CLIError("No executable cleanup; inspect source/producer instructions")
        }
        let report = try ScanEngine(environment: environment).scan(inputs.request)
        try mutation.apply(cleanup.batch, report: report, environment: environment, output: output)
    }
}
