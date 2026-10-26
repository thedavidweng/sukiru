import Foundation

/// One requested hook change. `remove`, `remove-leftovers`, and `disable-producer` clean up;
/// `add`, `edit`, and `set-disable-all` write documented standalone sources (ADR-0014).
public struct HookCleanupRequest: Codable, Equatable, Sendable {
    public let action: String
    public let hookID: String?
    public let producer: String?
    /// `add`: the host, `user`/`project`/`local` scope, and project root for non-user scopes.
    public let host: PluginHost?
    public let scope: String?
    public let scopeRoot: String?
    public let event: String?
    /// `add`/`edit`: the group matcher; nil or empty matches every occurrence.
    public let matcher: String?
    public let handler: HookHandlerSpec?
    /// `set-disable-all`: the Claude Code settings file and its new value.
    public let path: String?
    public let disableAllHooks: Bool?

    public init(
        action: String = "remove", hookID: String? = nil, producer: String? = nil,
        host: PluginHost? = nil, scope: String? = nil, scopeRoot: String? = nil,
        event: String? = nil, matcher: String? = nil, handler: HookHandlerSpec? = nil,
        path: String? = nil, disableAllHooks: Bool? = nil
    ) {
        self.action = action
        self.hookID = hookID
        self.producer = producer
        self.host = host
        self.scope = scope
        self.scopeRoot = scopeRoot
        self.event = event
        self.matcher = matcher
        self.handler = handler
        self.path = path
        self.disableAllHooks = disableAllHooks
    }
}

public struct HookCleanupPlan: Codable, Sendable {
    public let batch: CommandBatch
    public let hooks: [AgentHook]
    public let helperPaths: [String]
    public let instructions: [String]
}

public struct HookFilePrecondition: Codable, Equatable, Sendable {
    public let path: String
    public let contentHash: String
    public let resolvedPath: String

    init(path: String, contentHash: String, resolvedPath: String? = nil) {
        self.path = path
        self.contentHash = contentHash
        self.resolvedPath =
            resolvedPath ?? URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// The `contentHash` of a source file that does not exist yet; never a SHA-256 digest.
    static let absent = "absent"

    public func validate() throws {
        if contentHash == Self.absent {
            guard DefaultFileSystemProbe().entryKind(atPath: path) == nil,
                URL(fileURLWithPath: path).resolvingSymlinksInPath().path == resolvedPath
            else { throw HookError("Hook source appeared: \(path). Rescan and replan.") }
            return
        }
        guard DefaultFileSystemProbe().entryKind(atPath: path) == .file,
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path == resolvedPath,
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            HookInventoryReader.hash(data) == contentHash
        else { throw HookError("Hook source or helper changed: \(path). Rescan and replan.") }
    }
}

/// Plans exact current definitions; the saved batch carries the scan's byte preconditions.
public struct HookCleanupPlanner: Sendable {
    let environment: SukiruEnvironment
    public init(environment: SukiruEnvironment) { self.environment = environment }

    public var orcaDisableAvailable: Bool {
        HookDiagnosis(environment: environment).executable("orca") != nil
    }

    public func plan(
        requests: [HookCleanupRequest], inventory: HookInventory
    ) throws -> HookCleanupPlan {
        let selection = try select(requests, inventory: inventory)
        var selected = selection.hooks
        let disableOrca = selection.disableOrca
        let instructions = selection.instructions
        let unique = Dictionary(grouping: selected, by: \.id).values.compactMap(\.first)
        selected = unique.sorted { $0.id < $1.id }
        var commands = try sourceCommands(
            removals: selected, edits: selection.edits, inventory: inventory)
        let helpers = helperPaths(selected: selected, inventory: inventory)
        for path in helpers {
            let hash = HookInventoryReader.hash(try Data(contentsOf: URL(fileURLWithPath: path)))
            commands.append(
                BatchCommand(
                    argv: ["sukiru-fileop", "delete-hook-helper", path, hash],
                    displayString: "Delete unreferenced hook helper " + path, owningCLI: .file,
                    intent: "Delete abandoned producer-owned helper: " + path,
                    dangerFlags: [.dangerousDeletion, .directFileOperation],
                    warning: "Only this file is removed: " + path,
                    captureRoots: [path],
                    hookPreconditions: [HookFilePrecondition(path: path, contentHash: hash)]))
        }
        if disableOrca {
            commands.append(try orcaCommand(inventory: inventory))
        }
        let affected =
            disableOrca
            ? selected + inventory.hooks.filter { $0.attribution.producer == "Orca" } : selected
        let refs =
            affected.map { hook in
                FindingRef(
                    findingID: hook.id, ruleID: "hook-cleanup", skillName: nil,
                    workspaceID: hook.source.scopeRoot == environment.home
                        ? "user" : "project:" + hook.source.scopeRoot)
            } + selection.edits.map { editReference($0, inventory: inventory) }
        let batch = CommandBatch(
            id: UUID().uuidString, createdAt: ISO8601DateFormatter().string(from: Date()),
            findingRefs: refs, decisions: [], commands: commands, snapshotID: nil, status: .proposed
        )
        return HookCleanupPlan(
            batch: batch, hooks: affected, helperPaths: helpers, instructions: instructions)
    }

    private struct Selection {
        var hooks: [AgentHook] = []
        var instructions: [String] = []
        var disableOrca = false
        var edits: [HookCleanupRequest] = []
    }

    private func select(
        _ requests: [HookCleanupRequest], inventory: HookInventory
    ) throws -> Selection {
        var selection = Selection()
        for request in requests {
            switch request.action {
            case "remove":
                try selectRemoval(request, inventory: inventory, into: &selection)
            case "remove-leftovers":
                guard let producer = request.producer, ["Muxy", "Orca"].contains(producer) else {
                    throw HookError("Choose an evidenced producer")
                }
                selection.hooks += inventory.hooks.filter {
                    $0.attribution.producer == producer && $0.health == .leftover && $0.canRemove
                        && $0.attribution.producerPresent == false
                }
            case "disable-producer":
                guard request.producer == "Orca",
                    inventory.hooks.contains(where: {
                        $0.attribution.producer == "Orca" && $0.attribution.producerPresent == true
                            && $0.source.writable
                    }), orcaDisableAvailable
                else {
                    throw HookError("Orca's supported disable command is not available")
                }
                selection.disableOrca = true
            case let action where Self.editActions.contains(action):
                selection.edits.append(request)
            default: throw HookError("Unsupported hook cleanup action")
            }
        }
        return selection
    }

    private func selectRemoval(
        _ request: HookCleanupRequest, inventory: HookInventory, into selection: inout Selection
    ) throws {
        guard let hook = inventory.hooks.first(where: { $0.id == request.hookID }) else {
            throw HookError("Hook no longer exists; rescan and replan")
        }
        guard hook.canRemove else {
            selection.instructions.append(
                "\(hook.event): inspect the managing source \(hook.source.managingSource ?? hook.source.path). "
                    + "Independent removal is unavailable."
            )
            return
        }
        let installedOrca =
            hook.attribution.producer == "Orca"
            && hook.attribution.producerPresent == true
        if installedOrca && orcaDisableAvailable {
            selection.instructions.append(
                "Orca manages this hook. Review disable-producer for Orca; "
                    + "it disables agent hooks across hosts."
            )
        } else {
            selection.hooks.append(hook)
        }
    }

    func removalCommand(path: String, hooks: [AgentHook]) throws -> BatchCommand {
        let source = hooks[0].source
        let precondition = HookFilePrecondition(
            path: path, contentHash: source.contentHash, resolvedPath: source.resolvedPath)
        try precondition.validate()
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let replacement =
            path.hasSuffix(".toml")
            ? try HookTOMLDocument(data).removing(hooks)
            : try HookJSONDocument(data).removing(hooks)
        let argv = [
            "sukiru-fileop", "replace-hook-source", path, source.contentHash,
            replacement.base64EncodedString()
        ]
        let entries = hooks.map {
            "\($0.event) group \($0.groupIndex) handler \($0.handlerIndex): "
                + ($0.details["command"]?.stringValue ?? $0.handlerType)
        }.joined(separator: "; ")
        let intent = "Remove exact definitions from \(path): \(entries)"
        let warning =
            hooks.contains { $0.attribution.producerPresent == true }
            ? "The installed producer may regenerate these hooks. " + intent : intent
        return BatchCommand(
            argv: argv, displayString: "Remove hooks from " + path,
            owningCLI: .file, intent: intent,
            dangerFlags: [.dangerousDeletion, .directFileOperation],
            warning: warning, captureRoots: [path], hookPreconditions: [precondition])
    }

    private func helperPaths(selected: [AgentHook], inventory: HookInventory) -> [String] {
        // Ambiguous commands or unreadable sources can hide references, so no helper is provably unreferenced.
        guard inventory.issues.isEmpty,
            !inventory.hooks.contains(where: {
                $0.handlerType == "command" && $0.targets.isEmpty
            })
        else { return [] }
        let ids = Set(selected.map(\.id))
        let remaining = inventory.hooks.filter { !ids.contains($0.id) }
        let candidates = selected.filter {
            $0.health == .leftover && $0.attribution.producerPresent == false
        }
        .flatMap { hook in
            let boundary =
                environment.home
                + (hook.attribution.producer == "Muxy"
                    ? "/Library/Application Support/Muxy/hooks" : "/.orca/agent-hooks")
            return hook.targets.filter { $0.hasPrefix(boundary + "/") }
        }
        return Set(candidates).filter { path in
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            let home = URL(fileURLWithPath: environment.home).resolvingSymlinksInPath().path
            let expected = home + String(path.dropFirst(environment.home.count))
            return DefaultFileSystemProbe().entryKind(atPath: path) == .file
                && resolved == expected
                && !remaining.contains { HookFileMutation.references($0, path: path) }
        }.sorted()
    }

    private func orcaCommand(inventory: HookInventory) throws -> BatchCommand {
        let hooks = inventory.hooks.filter {
            $0.attribution.producer == "Orca" && $0.source.writable
        }
        var preconditions: [HookFilePrecondition] = []
        for hook in hooks where !preconditions.contains(where: { $0.path == hook.source.path }) {
            let condition = HookFilePrecondition(
                path: hook.source.path, contentHash: hook.source.contentHash,
                resolvedPath: hook.source.resolvedPath)
            try condition.validate()
            preconditions.append(condition)
        }
        let argv = ["orca", "agent", "hooks", "off", "--json"]
        let warning =
            "Disables Orca agent status hooks across hosts, not just this entry. "
            + "Orca owns profile state, runtime, and other host effects; "
            + "file rollback restores captured hook sources and payloads only. Re-enable in Orca if needed."
        return BatchCommand(
            argv: argv, displayString: BatchCommand.display(for: argv), owningCLI: .orca,
            intent: "Disable producer-managed Orca agent hooks", dangerFlags: [.backendStateChange],
            warning: warning,
            captureRoots: preconditions.map(\.path) + [environment.home + "/.orca/agent-hooks"],
            hookPreconditions: preconditions)
    }
}
