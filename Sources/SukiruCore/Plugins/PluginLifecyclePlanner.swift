import Foundation

/// Maps verified host routes to the existing snapshot-protected command pipeline.
public struct PluginLifecyclePlanner: Sendable {
    let environment: SukiruEnvironment

    public init(environment: SukiruEnvironment) { self.environment = environment }

    public func capabilities(host: PluginHost) throws -> PluginLifecycleCapabilities {
        let probe = PluginLifecycleProbe(environment: environment)
        let version = try probe.version(host: host)
        if host == .cursor { return try cursorCapabilities(probe: probe, version: version) }
        if host == .antigravity {
            return try antigravityCapabilities(probe: probe, version: version)
        }
        if host == .droid { return try droidCapabilities(probe: probe, version: version) }
        if host == .hermes { return try hermesCapabilities(probe: probe, version: version) }
        try probe.help(host: host, arguments: ["plugin"], requiredFlags: [])
        var native: [String] = []
        var limits: [String: String] = [:]
        let noInventory = PluginInventory(installations: [], marketplaces: [], issues: [])
        for action in PluginLifecycleRequest.actions where action != "disable-local" {
            let request = PluginLifecycleRequest(
                host: host, action: action,
                target: action == "list" ? "*" : "plugin@configured-marketplace",
                scope: "user", scopeRoot: environment.home)
            if let limit = limitation(request, version: version, inventory: noInventory) {
                limits[action] = limit
            } else {
                native.append(action)
            }
        }
        return PluginLifecycleCapabilities(
            host: host, version: version, nativeCandidates: native, limits: limits)
    }

    public func plan(
        requests: [PluginLifecycleRequest], inventory: PluginInventory
    ) throws -> PluginLifecyclePlan {
        var commands: [BatchCommand] = []
        var instructions: [String] = []
        let probe = PluginLifecycleProbe(environment: environment)
        var versions: [PluginHost: String] = [:]
        for request in requests {
            try validate(request)
            let version: String
            let localCursor =
                request.host == .cursor
                && (request.action == "disable-local" || cursorLimitation(request) != nil)
            if localCursor || Self.isCodexEnablement(request) || Self.isDroidSettingsEdit(request) {
                version = "not probed"
            } else if let known = versions[request.host] {
                version = known
            } else {
                version = try probe.version(host: request.host)
                versions[request.host] = version
            }
            switch try operation(request, inventory: inventory, version: version, probe: probe) {
            case .native(let command): commands.append(command)
            case .instructions(let text): instructions.append(text)
            }
        }
        commands = try AgentExtensionMutation.merged(commands)
        let refs = requests.enumerated().map { index, request in
            FindingRef(
                findingID: "plugin:\(index)", ruleID: "plugin-lifecycle", skillName: nil,
                workspaceID: request.scope == "user" ? "user" : "project:" + request.scopeRoot)
        }
        let batch =
            commands.isEmpty
            ? nil
            : CommandBatch(
                id: UUID().uuidString,
                createdAt: ISO8601DateFormatter().string(from: Date()), findingRefs: refs,
                decisions: [],
                commands: commands, snapshotID: nil, status: .proposed)
        return PluginLifecyclePlan(
            batch: batch, instructions: instructions, impacts: commands.map(\.intent))
    }

    private enum Operation {
        case native(BatchCommand)
        case instructions(String)
    }

    private func operation(
        _ request: PluginLifecycleRequest, inventory: PluginInventory,
        version: String, probe: PluginLifecycleProbe
    ) throws -> Operation {
        if request.action == "disable-local" {
            return .native(
                try PluginLocalDisable.command(
                    request: request, inventory: inventory,
                    environment: environment, hostVersion: version))
        }
        if let edit = try settingsEdit(request, inventory: inventory) { return .native(edit) }
        if let limit = limitation(request, version: version, inventory: inventory) {
            return .instructions(limit)
        }
        let args = try verifiedArguments(
            request, inventory: inventory, version: version, probe: probe)
        let v1ConfigRoot =
            PluginHostContract(host: request.host, version: version) == .openCodeV1
                && request.scope != "user"
            ? try probe.openCodeV1ConfigRoot(directory: request.scopeRoot) : nil
        let capture = try PluginLifecycleCapture(environment: environment).roots(
            request: request, inventory: inventory)
        if capture.requiresHostApproval {
            return .instructions(
                "\(request.target): source commands or headersHelper require host review. "
                    + "Open \(request.host.rawValue) and run the official operation through its approval workflow; "
                    + "then refresh Sukiru. No pending request or automatic resumption is assumed.")
        }
        let impact =
            try impact(request, inventory: inventory)
            + (v1ConfigRoot.map { " Actual configuration target: \($0)." } ?? "")
            + effectsWarning(request, version: version) + npmCacheNote(request)
        let extraPaths = try PluginCaptureLinks.expand(
            v1ConfigRoot.map { [$0] } ?? [], environment: environment)
        let capturePaths = Array(Set(capture.paths + extraPaths)).sorted()
        let destructive = request.action == "remove" || request.action == "marketplace-remove"
        let flags: [DangerFlag] =
            (destructive ? [.dangerousDeletion] : [])
            + effectsFlags(request, version: version)
        return .native(
            BatchCommand(
                argv: args, displayString: BatchCommand.display(for: args),
                owningCLI: owner(request.host), intent: impact,
                dangerFlags: flags, warning: impact,
                workingDirectory: [.opencode, .antigravity, .droid].contains(request.host)
                    ? request.scopeRoot
                    : (["user", "managed"].contains(request.scope) ? nil : request.scopeRoot),
                captureRoots: capturePaths))
    }

    /// Documented settings keys the host has no command for (ADR-0014 rule 2).
    private func settingsEdit(
        _ request: PluginLifecycleRequest, inventory: PluginInventory
    ) throws -> BatchCommand? {
        if Self.isCodexEnablement(request) {
            return try CodexPluginEnablement.command(
                request: request, inventory: inventory, environment: environment)
        }
        return Self.isDroidSettingsEdit(request)
            ? try droidSettingsEdit(request, inventory: inventory) : nil
    }

    private func verifiedArguments(
        _ request: PluginLifecycleRequest, inventory: PluginInventory,
        version: String, probe: PluginLifecycleProbe
    ) throws -> [String] {
        if request.host == .cursor { return try cursorArguments(request) }
        if request.host == .antigravity {
            return try antigravityArguments(request, probe: probe)
        }
        if request.host == .droid {
            return try droidArguments(request, inventory: inventory, probe: probe)
        }
        if request.host == .hermes { return try hermesArguments(request, probe: probe) }
        let args = try arguments(request, inventory: inventory, version: version)
        try probe.help(
            host: request.host,
            arguments: Array(args.dropFirst().prefix(helpArgumentCount(request, version: version))),
            requiredFlags: args.filter { ["--scope", "--json", "--global", "--force"].contains($0) }
        )
        return args
    }

    private func limitation(
        _ request: PluginLifecycleRequest, version: String, inventory: PluginInventory
    ) -> String? {
        if request.host != .antigravity, ["import", "validate", "link"].contains(request.action) {
            return "This operation is supported through Antigravity's native plugin interface only."
        }
        return switch request.host {
        case .claude: claudeLimitation(request, version: version)
        case .codex: codexLimitation(request, version: version, inventory: inventory)
        case .opencode: openCodeLimitation(request, version: version, inventory: inventory)
        case .cursor: cursorLimitation(request)
        case .antigravity: antigravityLimitation(request, version: version, inventory: inventory)
        case .droid: droidLimitation(request, version: version, inventory: inventory)
        case .hermes: hermesLimitation(request, version: version, inventory: inventory)
        }
    }

    private func arguments(
        _ request: PluginLifecycleRequest, inventory: PluginInventory, version: String
    ) throws -> [String] {
        if PluginHostContract(host: request.host, version: version) == .openCodeV1 {
            return openCodeV1Arguments(request)
        }
        var args = [request.host.rawValue, "plugin"]
        let marketplace = request.action.hasPrefix("marketplace-")
        if marketplace {
            guard request.host != .opencode else {
                throw PluginLifecycleError(message: "No OpenCode marketplace interface")
            }
            args.append("marketplace")
            let action = String(request.action.dropFirst("marketplace-".count))
            args.append(
                action == "refresh" ? (request.host == .codex ? "upgrade" : "update") : action)
            if action != "add" {
                try validateMarketplaceTarget(request, action: action, inventory: inventory)
            }
        } else {
            let action =
                request.action == "install" && request.host != .claude ? "add" : request.action
            args.append(action)
            if request.action == "install" {
                try validateInstallMarketplace(request, inventory: inventory)
            }
        }
        if request.host != .opencode || request.target != "*" {
            args.append(request.target)
        }
        if request.host == .claude && !(marketplace && request.action == "marketplace-refresh") {
            args += ["--scope", request.scope]
        }
        if request.host != .opencode { args.append("--json") }
        return args
    }

    private func owner(_ host: PluginHost) -> OwningCLI {
        switch host {
        case .claude: .claude
        case .codex: .codex
        case .opencode: .opencode
        case .cursor: .cursor
        case .antigravity: .antigravity
        case .droid: .droid
        case .hermes: .hermes
        }
    }

}
