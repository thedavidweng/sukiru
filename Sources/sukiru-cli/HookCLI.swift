import Foundation
import SukiruCore

struct HookInventoryCommand {
    var inputs: ScopeOptions
    var output: OutputOptions
    func run() throws {
        let report = try ScanEngine(environment: cliEnvironment(roots: inputs.roots)).scan(
            inputs.request)
        try output.render(
            report, lines: ["Hook inventory: \(String(describing: report.hookInventory))"])
    }
}

struct HookPlanCommand {
    var requests: String
    var inputs: ScopeOptions
    var output: OutputOptions
    func run() throws {
        let environment = try cliEnvironment(roots: inputs.roots)
        let plugins = PluginInventoryReader(environment: environment).read(inputs.request)
        let inventory = HookInventoryReader(environment: environment).read(
            inputs.request, plugins: plugins)
        let plan = try HookCleanupPlanner(environment: environment).plan(
            requests: readJSON([HookCleanupRequest].self, from: requests), inventory: inventory,
            extensions: AgentExtensionReader(environment: environment).read())
        try output.render(plan, lines: plan.batch.reviewLines + plan.instructions)
    }
}

struct HookExecuteCommand {
    var plan: String
    var inputs: ScopeOptions
    var output: OutputOptions
    var mutation: MutationOptions
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

extension CLI {
    static let hookCommands: [CLICommand] = [
        CLICommand(
            path: "hooks",
            abstract: "Advanced: passive hook inventory and explicit reviewed hook changes.",
            options: []),
        CLICommand(
            path: "hooks inventory", abstract: "Read hook sources and passive diagnoses.",
            options: scopeOptions + outputOptions
        ) { arguments in
            let command = HookInventoryCommand(
                inputs: try ScopeOptions(arguments), output: OutputOptions(arguments))
            try command.run()
        },
        CLICommand(
            path: "hooks plan",
            abstract:
                "Build cleanup, add, edit, or disableAllHooks changes from explicit requests.",
            options: [CLIOption("requests", takesValue: true, help: "", required: true)]
                + scopeOptions
                + outputOptions
        ) { arguments in
            let command = HookPlanCommand(
                requests: try arguments.required("requests"), inputs: try ScopeOptions(arguments),
                output: OutputOptions(arguments))
            try command.run()
        },
        CLICommand(
            path: "hooks execute",
            abstract: "Execute a reviewed hook plan with danger acknowledgement.",
            options: [CLIOption("plan", takesValue: true, help: "", required: true)] + scopeOptions
                + outputOptions
                + mutationOptions
        ) { arguments in
            let command = HookExecuteCommand(
                plan: try arguments.required("plan"), inputs: try ScopeOptions(arguments),
                output: OutputOptions(arguments), mutation: try MutationOptions(arguments))
            try command.run()
        }
    ]
}
