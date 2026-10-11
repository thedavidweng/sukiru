import Foundation
import SukiruCore

struct PluginList {
    var inputs: ScopeOptions
    var output: OutputOptions
    func run() throws {
        let inventory = PluginInventoryReader(environment: try cliEnvironment(roots: inputs.roots))
            .read(inputs.request)
        let installations = inventory.installations.filter {
            inputs.host == nil || $0.host == inputs.pluginHost
        }
        try output.render(
            installations,
            lines: installations.map {
                "\($0.host.rawValue) / \($0.scope) / \($0.scopeRoot): \($0.identifier) [\($0.source)] "
                    + "status=\($0.installationStatus) format=\($0.format ?? "host-specific") "
                    + "enabled=\($0.enablement.rawValue) loaded=\($0.loadStatus)"
            })
        for issue in inputs.selectedPlugins(inventory).issues { emitError(issue.message) }
    }
}

struct PluginHealth {
    var inputs: ScopeOptions
    var output: OutputOptions
    func run() throws {
        let inventory = PluginInventoryReader(environment: try cliEnvironment(roots: inputs.roots))
            .read(inputs.request)
        try output.render(
            inputs.selectedPlugins(inventory),
            lines: inventory.installations.filter {
                inputs.host == nil || $0.host == inputs.pluginHost
            }.map {
                "\($0.host.rawValue) / \($0.scopeRoot): \($0.identifier) "
                    + "enabled=\($0.enablement.rawValue), loaded=\($0.loadStatus)"
            } + inputs.selectedPlugins(inventory).healthFindings.map { "\($0.kind): \($0.path)" })
        for issue in inputs.selectedPlugins(inventory).issues { emitError(issue.message) }
    }
}

struct PluginCapabilities {
    var host: String
    var output: OutputOptions
    func run() throws {
        guard let pluginHost = resolvedPluginHost(for: host) else {
            throw CLIError("No Plugin interface for Agent Host \(host)")
        }
        let capabilities = try PluginLifecyclePlanner(environment: cliEnvironment()).capabilities(
            host: pluginHost)
        try output.render(
            capabilities,
            lines: [
                "\(host) \(capabilities.version)",
                "Supported: \(capabilities.nativeCandidates.joined(separator: ", "))"
            ]
                + capabilities.limits.keys.sorted().map {
                    "\($0): \(capabilities.limits[$0] ?? "")"
                })
    }
}

struct PluginOperationOptions {
    var target: String
    var inputs: ScopeOptions
    var settingsScope: String?
    var output: OutputOptions
    var mutation: MutationOptions

    func run(action: String) throws {
        let environment = try cliEnvironment(roots: inputs.roots)
        guard let hostName = inputs.host, let host = resolvedPluginHost(for: hostName) else {
            throw CLIError("Choose --host claude-code, codex, opencode, or cursor")
        }
        let targetScope = try inputs.installTarget(environment: environment)
        let root: String
        switch targetScope {
        case .user: root = environment.home
        case .project(let path): root = path
        }
        let scope: String
        switch (settingsScope, targetScope) {
        case (nil, _): scope = inputs.scope.rawValue
        case ("local", .project), ("managed", .user): scope = settingsScope ?? ""
        default:
            throw CLIError("--settings-scope local needs a project; managed needs user scope")
        }
        let request = PluginLifecycleRequest(
            host: host, action: action, target: target, scope: scope, scopeRoot: root)
        try runPluginRequests([request], inputs: inputs, output: output, mutation: mutation)
    }
}

func runPluginRequests(
    _ requests: [PluginLifecycleRequest], inputs: ScopeOptions,
    output: OutputOptions, mutation: MutationOptions
) throws {
    let environment = try cliEnvironment(roots: inputs.roots)
    let report = try ScanEngine(environment: environment).scan(inputs.mutationRequest)
    let inventory = PluginInventoryReader(environment: environment).read(inputs.request)
    let plan = try PluginLifecyclePlanner(environment: environment).plan(
        requests: requests, inventory: inventory)
    if mutation.dryRun || !plan.instructions.isEmpty || plan.batch == nil {
        try output.render(
            plan, lines: (plan.batch?.reviewLines ?? []) + plan.impacts + plan.instructions)
        if !mutation.dryRun && !plan.instructions.isEmpty {
            throw CLIError(
                "Operation requires the official host workflow; follow the reported instructions")
        }
        return
    }
    try mutation.apply(plan.batch, report: report, environment: environment, output: output)
}

struct PluginMarketplaceList {
    var inputs: ScopeOptions
    var output: OutputOptions
    func run() throws {
        let inventory = PluginInventoryReader(environment: try cliEnvironment(roots: inputs.roots))
            .read(inputs.request)
        let marketplaces = inventory.marketplaces.filter {
            inputs.host == nil || $0.host == inputs.pluginHost
        }
        try output.render(
            marketplaces,
            lines: marketplaces.map {
                "\($0.host.rawValue) / \($0.scope) / \($0.scopeRoot): \($0.name) \($0.source) "
                    + "[\($0.evidence ?? "configured")]"
            })
    }
}

struct PluginPlan {
    var requests: String
    var inputs: ScopeOptions
    var output: OutputOptions
    func run() throws {
        var mutation = MutationOptions()
        mutation.dryRun = true
        try runPluginRequests(
            readJSON([PluginLifecycleRequest].self, from: requests), inputs: inputs, output: output,
            mutation: mutation)
    }
}

struct PluginExecute {
    var requests: String
    var inputs: ScopeOptions
    var output: OutputOptions
    var mutation: MutationOptions
    func run() throws {
        try runPluginRequests(
            readJSON([PluginLifecycleRequest].self, from: requests), inputs: inputs, output: output,
            mutation: mutation)
    }
}

struct PluginInstall {
    var options: PluginOperationOptions
    func run() throws { try options.run(action: "install") }
}

struct PluginUpdate {
    var options: PluginOperationOptions
    func run() throws { try options.run(action: "update") }
}

struct PluginEnable {
    var options: PluginOperationOptions
    func run() throws { try options.run(action: "enable") }
}

struct PluginDisable {
    var options: PluginOperationOptions
    func run() throws { try options.run(action: "disable") }
}

struct PluginDisableLocal {
    var options: PluginOperationOptions
    func run() throws { try options.run(action: "disable-local") }
}

struct PluginUninstall {
    var options: PluginOperationOptions
    func run() throws { try options.run(action: "remove") }
}

struct PluginMarketplaceAdd {
    var options: PluginOperationOptions
    func run() throws { try options.run(action: "marketplace-add") }
}

struct PluginMarketplaceRefresh {
    var options: PluginOperationOptions
    func run() throws { try options.run(action: "marketplace-refresh") }
}

struct PluginMarketplaceRemove {
    var options: PluginOperationOptions
    func run() throws { try options.run(action: "marketplace-remove") }
}

func resolvedPluginHost(for host: String) -> PluginHost? {
    switch host {
    case "claude-code": .claude
    case "codex": .codex
    case "opencode": .opencode
    case "cursor": .cursor
    default: nil
    }
}

extension CLI {
    static let pluginCommands: [CLICommand] = [
        CLICommand(
            path: "plugins",
            abstract: "Agent Plugin inventory, health, lifecycle, and host-owned marketplaces.",
            options: []),
        CLICommand(
            path: "plugins list",
            abstract: "List distinct Plugin Installations by host and concrete scope.",
            options: scopeOptions + outputOptions
        ) { arguments in
            let command = PluginList(
                inputs: try ScopeOptions(arguments), output: OutputOptions(arguments))
            try command.run()
        },
        CLICommand(
            path: "plugins health",
            abstract: "Inspect plugin enablement, load status, and diagnosed Problems passively.",
            options: scopeOptions + outputOptions
        ) { arguments in
            let command = PluginHealth(
                inputs: try ScopeOptions(arguments), output: OutputOptions(arguments))
            try command.run()
        },
        CLICommand(
            path: "plugins capabilities",
            abstract: "Explicitly probe the host-supported operations.",
            options: [
                CLIOption(
                    "host", takesValue: true,
                    help: "Agent Host: claude-code, codex, opencode, or cursor.", required: true)
            ] + outputOptions
        ) { arguments in
            let command = PluginCapabilities(
                host: try arguments.required("host"), output: OutputOptions(arguments))
            try command.run()
        },
        CLICommand(
            path: "plugins marketplaces", abstract: "Host-owned marketplace operations.",
            options: []),
        CLICommand(
            path: "plugins marketplaces list", abstract: "Read locally configured marketplaces.",
            options: scopeOptions + outputOptions
        ) { arguments in
            let command = PluginMarketplaceList(
                inputs: try ScopeOptions(arguments), output: OutputOptions(arguments))
            try command.run()
        },
        CLICommand(
            path: "plugins plan", abstract: "Advanced: build a Plugin plan from explicit requests.",
            options: [CLIOption("requests", takesValue: true, help: "", required: true)]
                + scopeOptions
                + outputOptions
        ) { arguments in
            let command = PluginPlan(
                requests: try arguments.required("requests"), inputs: try ScopeOptions(arguments),
                output: OutputOptions(arguments))
            try command.run()
        },
        CLICommand(
            path: "plugins execute",
            abstract: "Advanced: execute explicit Plugin requests with the shared safety gates.",
            options: [CLIOption("requests", takesValue: true, help: "", required: true)]
                + scopeOptions
                + outputOptions + mutationOptions
        ) { arguments in
            let command = PluginExecute(
                requests: try arguments.required("requests"), inputs: try ScopeOptions(arguments),
                output: OutputOptions(arguments), mutation: try MutationOptions(arguments))
            try command.run()
        },
        CLICommand(
            path: "plugins install", abstract: "Plan or perform install through the official host.",
            options: pluginOperationOptions,
            argument: CLIPositional(
                name: "target", required: true,
                help: "Host-recognized plugin or marketplace identifier/source.")
        ) { arguments in
            let command = PluginInstall(options: try PluginOperationOptions(arguments))
            try command.run()
        },
        CLICommand(
            path: "plugins update", abstract: "Plan or perform update through the official host.",
            options: pluginOperationOptions,
            argument: CLIPositional(
                name: "target", required: true,
                help: "Host-recognized plugin or marketplace identifier/source.")
        ) { arguments in
            let command = PluginUpdate(options: try PluginOperationOptions(arguments))
            try command.run()
        },
        CLICommand(
            path: "plugins enable", abstract: "Plan or perform enable through the official host.",
            options: pluginOperationOptions,
            argument: CLIPositional(
                name: "target", required: true,
                help: "Host-recognized plugin or marketplace identifier/source.")
        ) { arguments in
            let command = PluginEnable(options: try PluginOperationOptions(arguments))
            try command.run()
        },
        CLICommand(
            path: "plugins disable", abstract: "Plan or perform disable through the official host.",
            options: pluginOperationOptions,
            argument: CLIPositional(
                name: "target", required: true,
                help: "Host-recognized plugin or marketplace identifier/source.")
        ) { arguments in
            let command = PluginDisable(options: try PluginOperationOptions(arguments))
            try command.run()
        },
        CLICommand(
            path: "plugins disable-local",
            abstract:
                "Move an incompatible local plugin file out of host discovery (snapshot-protected).",
            options: pluginOperationOptions,
            argument: CLIPositional(
                name: "target", required: true,
                help: "Host-recognized plugin or marketplace identifier/source.")
        ) { arguments in
            let command = PluginDisableLocal(options: try PluginOperationOptions(arguments))
            try command.run()
        },
        CLICommand(
            path: "plugins uninstall",
            abstract: "Plan or perform remove through the official host.",
            options: pluginOperationOptions,
            argument: CLIPositional(
                name: "target", required: true,
                help: "Host-recognized plugin or marketplace identifier/source.")
        ) { arguments in
            let command = PluginUninstall(options: try PluginOperationOptions(arguments))
            try command.run()
        },
        CLICommand(
            path: "plugins marketplaces add",
            abstract: "Plan or perform marketplace-add through the official host.",
            options: pluginOperationOptions,
            argument: CLIPositional(
                name: "target", required: true,
                help: "Host-recognized plugin or marketplace identifier/source.")
        ) { arguments in
            let command = PluginMarketplaceAdd(options: try PluginOperationOptions(arguments))
            try command.run()
        },
        CLICommand(
            path: "plugins marketplaces refresh",
            abstract: "Plan or perform marketplace-refresh through the official host.",
            options: pluginOperationOptions,
            argument: CLIPositional(
                name: "target", required: true,
                help: "Host-recognized plugin or marketplace identifier/source.")
        ) { arguments in
            let command = PluginMarketplaceRefresh(options: try PluginOperationOptions(arguments))
            try command.run()
        },
        CLICommand(
            path: "plugins marketplaces remove",
            abstract: "Plan or perform marketplace-remove through the official host.",
            options: pluginOperationOptions,
            argument: CLIPositional(
                name: "target", required: true,
                help: "Host-recognized plugin or marketplace identifier/source.")
        ) { arguments in
            let command = PluginMarketplaceRemove(options: try PluginOperationOptions(arguments))
            try command.run()
        }
    ]
}
