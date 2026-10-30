import Foundation

/// ADR-0014 rule 2: Codex has no command to enable or disable one plugin but
/// documents `[plugins."<id>"] enabled = true|false` in `config.toml`. The
/// edit touches only that value (or inserts it right after the table header)
/// and refuses every layout it cannot change exactly.
enum CodexPluginEnablement {
    static func configPath(
        scope: String, root: String, environment: SukiruEnvironment
    ) -> String {
        if scope == "user" {
            let config =
                environment.externalValue(for: "CODEX_HOME")
                ?? HostPathResolver.join(environment.home, ".codex")
            return HostPathResolver.join(config, "config.toml")
        }
        return HostPathResolver.join(root, ".codex/config.toml")
    }

    static func command(
        request: PluginLifecycleRequest, inventory: PluginInventory,
        environment: SukiruEnvironment
    ) throws -> BatchCommand {
        guard ["user", "project"].contains(request.scope) else {
            throw PluginLifecycleError(
                message: "Codex plugin enablement lives in the user or project config.toml")
        }
        guard
            inventory.installations.contains(where: {
                $0.host == .codex && $0.identifier == request.target
                    && $0.scope == request.scope && $0.scopeRoot == request.scopeRoot
            })
        else {
            throw PluginLifecycleError(
                message: "Codex plugin is not configured in the selected scope: " + request.target)
        }
        let path = configPath(
            scope: request.scope, root: request.scopeRoot, environment: environment)
        let resolved = try editablePath(path)
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw PluginLifecycleError(
                message: "Cannot read \(path): \(error.localizedDescription)")
        }
        let enabled = request.action == "enable"
        let replacement = try edit(data, identifier: request.target, enabled: enabled, path: path)
        let precondition = HookFilePrecondition(
            path: path, contentHash: HookInventoryReader.hash(data), resolvedPath: resolved)
        let operation = FileOperation.replaceConfigSource(
            path: path, hash: precondition.contentHash,
            contents: replacement.base64EncodedString(), pluginID: request.target,
            enabled: enabled)
        let key = "[plugins.\"\(request.target)\"] enabled = \(enabled)"
        let intent =
            "Set \(key) in \(path). Only this documented Codex key changes; "
            + "every other byte of the file is kept."
        return BatchCommand(
            argv: operation.argv,
            displayString: "Set \(key) in \(path)", owningCLI: .file, intent: intent,
            dangerFlags: [.directFileOperation],
            warning: intent
                + " Codex reads it when its next session starts. "
                + "Snapshot rollback restores the file.",
            captureRoots: [path], hookPreconditions: [precondition])
    }

    /// The resolved path of a regular, non-system config file.
    private static func editablePath(_ path: String) throws -> String {
        guard DefaultFileSystemProbe().entryKind(atPath: path) == .file else {
            throw PluginLifecycleError(
                message: "\(path) is not a regular file; Sukiru edits only a regular config.toml")
        }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard !["/etc/", "/private/etc/", "/Library/"].contains(where: { resolved.hasPrefix($0) })
        else {
            throw PluginLifecycleError(message: "Managed or system Codex config is read-only")
        }
        return resolved
    }

    /// Re-checks the reviewed precondition and replacement right before an
    /// atomic write that keeps the file's permissions.
    static func replace(
        path: String, hash: String, contents: String, pluginID: String, enabled: Bool
    ) throws {
        try HookFilePrecondition(path: path, contentHash: hash).validate()
        guard let replacement = Data(base64Encoded: contents) else {
            throw FileOperationError("Invalid config replacement data")
        }
        let current = try Data(contentsOf: URL(fileURLWithPath: path))
        guard
            try edit(current, identifier: pluginID, enabled: enabled, path: path) == replacement
        else {
            throw FileOperationError(
                "The reviewed replacement no longer matches \(path). Rescan and replan.")
        }
        try writeAtomically(replacement, to: path)
    }

    /// The file with only the plugin's `enabled` value changed or inserted,
    /// verified to read back through `PluginTOMLReader` as exactly that change.
    static func edit(
        _ data: Data, identifier: String, enabled: Bool, path: String
    ) throws -> Data {
        let refuse = { (reason: String) in
            PluginLifecycleError(
                message: "Cannot change \(identifier) in \(path): \(reason). Edit it in Codex.")
        }
        guard let text = String(data: data, encoding: .utf8),
            let before = try? PluginTOMLReader.tables(text: text)
        else { throw refuse("the file is not readable plugin TOML") }
        let layout = try CodexPluginLayout(Array(data), identifier: identifier, refuse: refuse)
        guard let header = layout.header else {
            throw refuse("there is no [plugins.\"\(identifier)\"] table")
        }
        let table = "plugins." + identifier
        guard before[table]?["enabled"] == layout.value.map({ String($0) }) else {
            throw refuse("the table layout is ambiguous")
        }
        if (layout.value ?? true) == enabled {
            throw refuse("it is already \(enabled ? "enabled" : "disabled")")
        }
        var bytes = Array(data)
        let value = Array(String(enabled).utf8)
        if let range = layout.valueRange {
            bytes.replaceSubrange(range, with: value)
        } else {
            let terminator = Array(bytes[header.contentEnd..<header.end])
            let line =
                terminator.isEmpty
                ? Array("\nenabled = ".utf8) + value
                : Array("enabled = ".utf8) + value + terminator
            bytes.insert(contentsOf: line, at: header.end)
        }
        var expected = before
        expected[table, default: [:]]["enabled"] = String(enabled)
        guard let result = String(bytes: bytes, encoding: .utf8),
            (try? PluginTOMLReader.tables(text: result)) == expected
        else { throw refuse("the edited file would not read back as intended") }
        return Data(bytes)
    }

    /// Writes beside the file and renames over it, keeping its permissions
    /// (Codex config can hold credentials).
    static func writeAtomically(_ data: Data, to path: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let mode = mode_t((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600)
        let url = URL(fileURLWithPath: path)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).sukiru-\(UUID().uuidString)").path
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard descriptor >= 0 else {
            throw FileOperationError("Cannot create a temporary file beside \(path)")
        }
        let written = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return buffer.isEmpty }
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, base + offset, buffer.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        let synced = fchmod(descriptor, mode) == 0 && fsync(descriptor) == 0
        close(descriptor)
        guard written, synced, rename(temporary, path) == 0 else {
            unlink(temporary)
            throw FileOperationError("Cannot write \(path)")
        }
    }
}
