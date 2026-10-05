import ArgumentParser
import Foundation
import SukiruCore

struct Plugins: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Agent Plugin inventory, health, lifecycle, and host-owned marketplaces.",
        subcommands: [
            PluginList.self, PluginHealth.self, PluginCapabilities.self, PluginInstall.self,
            PluginUpdate.self, PluginEnable.self, PluginDisable.self, PluginDisableLocal.self,
            PluginUninstall.self, PluginMarketplaces.self, PluginPlan.self, PluginExecute.self
        ])
}

struct PluginList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List distinct Plugin Installations by host and concrete scope.")
    @OptionGroup var inputs: ScopeOptions
    @OptionGroup var output: OutputOptions
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

struct PluginHealth: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "health",
        abstract: "Inspect plugin enablement, load status, and diagnosed Problems passively.")
    @OptionGroup var inputs: ScopeOptions
    @OptionGroup var output: OutputOptions
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

struct PluginCapabilities: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capabilities", abstract: "Explicitly probe the host-supported operations.")
    @Option(help: "Agent Host: claude-code, codex, opencode, or cursor.") var host: String
    @OptionGroup var output: OutputOptions
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

struct PluginOperationOptions: ParsableArguments {
    @Argument(help: "Host-recognized plugin or marketplace identifier/source.") var target: String
    @OptionGroup var inputs: ScopeOptions
    @Option(help: "Claude Code settings scope instead of --scope: local (with --root) or managed.")
    var settingsScope: String?
    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions

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

struct PluginMarketplaces: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "marketplaces", abstract: "Host-owned marketplace operations.",
        subcommands: [
            PluginMarketplaceList.self, PluginMarketplaceAdd.self, PluginMarketplaceRefresh.self,
            PluginMarketplaceRemove.self
        ])
}

struct PluginMarketplaceList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "Read locally configured marketplaces.")
    @OptionGroup var inputs: ScopeOptions
    @OptionGroup var output: OutputOptions
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

struct PluginPlan: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan", abstract: "Advanced: build a Plugin plan from explicit requests.")
    @Option var requests: String
    @OptionGroup var inputs: ScopeOptions
    @OptionGroup var output: OutputOptions
    func run() throws {
        var mutation = MutationOptions()
        mutation.dryRun = true
        try runPluginRequests(
            readJSON([PluginLifecycleRequest].self, from: requests), inputs: inputs, output: output,
            mutation: mutation)
    }
}

struct PluginExecute: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "execute",
        abstract: "Advanced: execute explicit Plugin requests with the shared safety gates.")
    @Option var requests: String
    @OptionGroup var inputs: ScopeOptions
    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    func run() throws {
        try runPluginRequests(
            readJSON([PluginLifecycleRequest].self, from: requests), inputs: inputs, output: output,
            mutation: mutation)
    }
}

struct PluginInstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install", abstract: "Plan or perform install through the official host.")
    @OptionGroup var options: PluginOperationOptions
    func run() throws { try options.run(action: "install") }
}

struct PluginUpdate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update", abstract: "Plan or perform update through the official host.")
    @OptionGroup var options: PluginOperationOptions
    func run() throws { try options.run(action: "update") }
}

struct PluginEnable: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable", abstract: "Plan or perform enable through the official host.")
    @OptionGroup var options: PluginOperationOptions
    func run() throws { try options.run(action: "enable") }
}

struct PluginDisable: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable", abstract: "Plan or perform disable through the official host.")
    @OptionGroup var options: PluginOperationOptions
    func run() throws { try options.run(action: "disable") }
}

struct PluginDisableLocal: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable-local",
        abstract:
            "Move an incompatible local plugin file out of host discovery (snapshot-protected).")
    @OptionGroup var options: PluginOperationOptions
    func run() throws { try options.run(action: "disable-local") }
}

struct PluginUninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall", abstract: "Plan or perform remove through the official host.")
    @OptionGroup var options: PluginOperationOptions
    func run() throws { try options.run(action: "remove") }
}

struct PluginMarketplaceAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Plan or perform marketplace-add through the official host.")
    @OptionGroup var options: PluginOperationOptions
    func run() throws { try options.run(action: "marketplace-add") }
}

struct PluginMarketplaceRefresh: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "refresh",
        abstract: "Plan or perform marketplace-refresh through the official host.")
    @OptionGroup var options: PluginOperationOptions
    func run() throws { try options.run(action: "marketplace-refresh") }
}

struct PluginMarketplaceRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Plan or perform marketplace-remove through the official host.")
    @OptionGroup var options: PluginOperationOptions
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
