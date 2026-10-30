import Foundation

/// File changes to one scanned add-on, each re-verified against the scan right before it runs.
enum AgentExtensionMutation {
    static func delete(path: String, hash: String, environment: SukiruEnvironment) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let reader = AgentExtensionReader(environment: environment)
        guard
            (reader.directories() + reader.disabledContainers()).contains(where: { $0.1 == parent })
        else { throw HookError("Not directly inside an extension directory: " + path) }
        guard AgentExtensionReader.hash(path) == hash else {
            throw HookError("Extension changed: \(path). Rescan and replan.")
        }
        try FileManager.default.removeItem(atPath: path)
    }

    static func removeHermesPlugin(
        path: String, hash: String, name: String, environment: SukiruEnvironment
    ) throws {
        guard path == AgentExtensionReader(environment: environment).hermesHome + "/config.yaml",
            let data = FileManager.default.contents(atPath: path),
            HookInventoryReader.hash(data) == hash
        else { throw HookError("Hermes config changed: \(path). Rescan and replan.") }
        guard let text = String(bytes: data, encoding: .utf8),
            let replacement = HermesPluginList(text).removing(name)
        else { throw HookError("\(name) is not in Hermes plugins.enabled") }
        try Data(replacement.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Applies documented edits to a file whose bytes still match the plan; an absent file
    /// starts empty, so rollback deletes what the edit created.
    static func edit(path: String, hash: String, edits: String) throws {
        try HookFilePrecondition(path: path, contentHash: hash).validate()
        let changes = try JSONDecoder().decode([AgentConfigEdit].self, from: Data(edits.utf8))
        let current =
            hash == HookFilePrecondition.absent
            ? Data() : try Data(contentsOf: URL(fileURLWithPath: path))
        let result = try AgentConfigEdit.apply(changes, to: current)
        if hash == HookFilePrecondition.absent {
            try FileManager.default.createDirectory(
                atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
                withIntermediateDirectories: true)
            try result.write(to: URL(fileURLWithPath: path), options: .atomic)
        } else {
            try CodexPluginEnablement.writeAtomically(result, to: path)
        }
    }

    /// Moves an Amp or OpenCode entry between its discovery folder and the disabled folder.
    static func move(
        path: String, hash: String, destination: String, environment: SukiruEnvironment
    ) throws {
        let reader = AgentExtensionReader(environment: environment)
        let folders = reader.directories() + reader.disabledContainers()
        let origin = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let target = URL(fileURLWithPath: destination).deletingLastPathComponent().path
        guard let source = folders.first(where: { $0.1 == origin }),
            folders.contains(where: { $0.0 == source.0 && $0.1 == target && $0.1 != origin }),
            [ExtensionHost.amp, .opencode].contains(source.0),
            URL(fileURLWithPath: path).lastPathComponent
                == URL(fileURLWithPath: destination).lastPathComponent
        else { throw HookError("Not a move between an extension folder and its disabled folder") }
        guard AgentExtensionReader.hash(path) == hash else {
            throw HookError("Extension changed: \(path). Rescan and replan.")
        }
        guard DefaultFileSystemProbe().entryKind(atPath: destination) == nil else {
            throw HookError("Something already exists at " + destination)
        }
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: path, toPath: destination)
    }

    static func command(_ item: AgentExtension) -> BatchCommand {
        let argv =
            item.kind == .enabledEntry
            ? ["sukiru-fileop", "remove-hermes-plugin", item.path, item.contentHash, item.name]
            : ["sukiru-fileop", "delete-agent-extension", item.path, item.contentHash]
        let intent =
            item.kind == .enabledEntry
            ? "Remove \(item.name) from Hermes plugins.enabled in \(item.path)"
            : "Delete \(item.host.rawValue) extension \(item.path)"
        return BatchCommand(
            argv: argv, displayString: intent, owningCLI: .file, intent: intent,
            dangerFlags: [.dangerousDeletion, .directFileOperation],
            warning: "Only this entry changes: " + item.path, captureRoots: [item.path])
    }

    static func moveCommand(
        _ item: AgentExtension, disable: Bool, reader: AgentExtensionReader
    ) throws -> BatchCommand {
        let folders = disable ? reader.disabledContainers() : reader.directories()
        guard [ExtensionHost.amp, .opencode].contains(item.host), item.kind != .configEntry,
            let folder = folders.first(where: { $0.0 == item.host })?.1
        else { throw HookError("\(item.host.rawValue) has no documented switch for \(item.name)") }
        let destination = folder + "/" + item.name
        let argv = [
            "sukiru-fileop", "move-agent-extension", item.path, item.contentHash, destination
        ]
        let intent =
            disable
            ? "Disable \(item.name) by moving it out of \(item.host.rawValue) discovery to \(destination)"
            : "Enable \(item.name) by moving it back to \(destination)"
        return BatchCommand(
            argv: argv, displayString: intent, owningCLI: .file, intent: intent,
            dangerFlags: [.directFileOperation],
            warning: intent + ". The host documents no per-file switch; only this entry moves.",
            captureRoots: [item.path, destination])
    }

    /// One edit command per file, ahead of host commands: each edit checks the bytes it was
    /// planned against, which a host command or an earlier edit would have changed.
    static func merged(_ commands: [BatchCommand]) throws -> [BatchCommand] {
        var paths: [String] = []
        var edits: [String: [AgentConfigEdit]] = [:]
        var intents: [String: [String]] = [:]
        var others: [BatchCommand] = []
        for command in commands {
            guard case .editAgentConfig(let path, _, let encoded)? = command.fileOperation else {
                others.append(command)
                continue
            }
            if edits[path] == nil { paths.append(path) }
            edits[path, default: []] += try JSONDecoder().decode(
                [AgentConfigEdit].self, from: Data(encoded.utf8))
            intents[path, default: []].append(command.intent)
        }
        return try paths.map { path in
            try editCommand(
                path: path, edits: edits[path] ?? [],
                intent: (intents[path] ?? []).joined(separator: "; "))
        } + others
    }

    static func editCommand(
        path: String, edits: [AgentConfigEdit], intent: String
    ) throws -> BatchCommand {
        let data = FileManager.default.contents(atPath: path)
        let hash = data.map(HookInventoryReader.hash) ?? HookFilePrecondition.absent
        if data != nil {
            guard DefaultFileSystemProbe().entryKind(atPath: path) == .file else {
                throw HookError(path + " is not a regular file")
            }
        }
        let before = data ?? Data()
        guard try AgentConfigEdit.apply(edits, to: before) != before else {
            throw HookError("Nothing to change: " + intent)
        }
        let encoded = String(bytes: try JSONEncoder().encode(edits), encoding: .utf8) ?? "[]"
        let argv = ["sukiru-fileop", "edit-agent-config", path, hash, encoded]
        return BatchCommand(
            argv: argv, displayString: intent, owningCLI: .file, intent: intent,
            dangerFlags: [.directFileOperation],
            warning: intent + ". Only this documented entry changes; every other byte is kept.",
            captureRoots: [path],
            hookPreconditions: [HookFilePrecondition(path: path, contentHash: hash)])
    }
}
