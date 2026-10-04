import Foundation

/// Maps verified host routes to the existing snapshot-protected command pipeline.
public struct PluginLifecyclePlanner: Sendable {
    let environment: SukiruEnvironment

    public init(environment: SukiruEnvironment) { self.environment = environment }

    public func capabilities(host: PluginHost) throws -> PluginLifecycleCapabilities {
        let probe = PluginLifecycleProbe(environment: environment)
        let version = try probe.version(host: host)
        if host == .cursor { return try cursorCapabilities(probe: probe, version: version) }
        try probe.help(host: host, arguments: ["plugin"], requiredFlags: [])
        var native: [String] = []
        var limits: [String: String] = [:]
        for action in PluginLifecycleRequest.actions where action != "disable-local" {
            let request = PluginLifecycleRequest(
                host: host, action: action,
                target: action == "list" ? "*" : "plugin@configured-marketplace",
                scope: "user", scopeRoot: environment.home)
            if let limit = limitation(request, version: version) {
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
            if localCursor {
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
        if let limit = limitation(request, version: version) { return .instructions(limit) }
        let args = try verifiedArguments(
            request, inventory: inventory, version: version, probe: probe)
        let v1ConfigRoot =
            request.host == .opencode
                && ["v1.18.34", "1.18.34"].contains(version)
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
            + effectsWarning(request, version: version)
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
                workingDirectory: request.host == .opencode
                    ? request.scopeRoot
                    : (["user", "managed"].contains(request.scope) ? nil : request.scopeRoot),
                captureRoots: capturePaths))
    }

    private func verifiedArguments(
        _ request: PluginLifecycleRequest, inventory: PluginInventory,
        version: String, probe: PluginLifecycleProbe
    ) throws -> [String] {
        if request.host == .cursor { return try cursorArguments(request) }
        let args = try arguments(request, inventory: inventory, version: version)
        try probe.help(
            host: request.host,
            arguments: Array(args.dropFirst().prefix(helpArgumentCount(request, version: version))),
            requiredFlags: args.filter { ["--scope", "--json", "--global", "--force"].contains($0) }
        )
        return args
    }

    private func validate(_ request: PluginLifecycleRequest) throws {
        guard PluginLifecycleRequest.actions.contains(request.action), !request.target.isEmpty,
            request.target != "*"
                || (request.host == .opencode
                    && ["list", "check", "update"].contains(request.action)),
            !request.target.hasPrefix("-"), !request.target.contains("\n"),
            !request.target.contains("\0")
        else { throw PluginLifecycleError(message: "Invalid plugin action or target") }
        let managedUpdate =
            request.host == .claude && request.action == "update" && request.scope == "managed"
        guard ["user", "project", "local"].contains(request.scope) || managedUpdate,
            request.scope == "user" || managedUpdate
                ? request.scopeRoot == environment.home
                : environment.projectRoots.contains(request.scopeRoot)
        else {
            throw PluginLifecycleError(
                message: "Scope must identify the user home or an added project")
        }
    }

    private func limitation(_ request: PluginLifecycleRequest, version: String) -> String? {
        switch request.host {
        case .claude: claudeLimitation(request, version: version)
        case .codex: codexLimitation(request, version: version)
        case .opencode: openCodeLimitation(request, version: version)
        case .cursor: cursorLimitation(request)
        }
    }

    private func claudeLimitation(_ request: PluginLifecycleRequest, version: String) -> String? {
        guard version == "2.1.288" else {
            return "Claude \(version) has no verified lifecycle contract; use the host."
        }
        if ["replace", "list"].contains(request.action) {
            return "Use Claude's install/update interfaces or passive Library inventory."
        }
        if request.action == "check" {
            return "Claude exposes no verified passive single-plugin update check."
        }
        return nil
    }

    private func codexLimitation(_ request: PluginLifecycleRequest, version: String) -> String? {
        guard version == "0.160.0" else {
            return "Codex \(version) has no verified lifecycle contract; use the host."
        }
        if request.scope != "user" {
            return
                "Codex plugin mutations support user scope only; project configuration is not rewritten."
        }
        if ["enable", "disable", "update", "check", "replace", "list"].contains(request.action) {
            return
                "Codex exposes no individual \(request.action) operation. "
                + "Marketplace refresh updates the whole configured Git marketplace; "
                + "feature flags are not plugin enablement."
        }
        return nil
    }

    private func arguments(
        _ request: PluginLifecycleRequest, inventory: PluginInventory, version: String
    ) throws -> [String] {
        if request.host == .opencode && ["v1.18.34", "1.18.34"].contains(version) {
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
                guard
                    inventory.marketplaces.contains(where: {
                        $0.host == request.host && $0.name == request.target
                    })
                else {
                    throw PluginLifecycleError(
                        message: "Marketplace is not configured: " + request.target)
                }
            }
        } else {
            let action =
                request.action == "install" && request.host != .claude ? "add" : request.action
            args.append(action)
            let curated =
                request.host == .codex && request.target.hasSuffix("@openai-curated-remote")
            if request.action == "install", request.host != .opencode, !curated {
                let pieces = request.target.split(separator: "@", maxSplits: 1).map(String.init)
                guard pieces.count == 2,
                    inventory.marketplaces.contains(where: {
                        $0.host == request.host && $0.name == pieces[1]
                            && $0.plugins.contains(where: { $0.name == pieces[0] })
                    })
                else {
                    throw PluginLifecycleError(
                        message: "Choose a plugin from a configured host marketplace")
                }
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
        }
    }

}
