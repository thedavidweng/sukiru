import Foundation

/// The direct file operations a batch may carry as `sukiru-fileop <verb>
/// <path>…` commands (ADR-0007). None writes a ledger: they act only where no
/// official CLI can — an ownerless payload, a dead link, the link ↔ copy
/// mode of a host-folder placement, or a leftover host folder. The executor parses the argv back into
/// this type, so a malformed or unknown verb never runs.
public enum FileOperation: Equatable, Sendable {
    /// Delete an ownerless skill directory.
    case deleteDirectory(String)
    /// Delete a symlink (dangling or not); never follows it. Already absent
    /// counts as done, so a CLI removal earlier in the batch is harmless.
    case deleteLink(String)
    /// Replace a physical copy (or a link elsewhere) with a symlink to
    /// `target`.
    case relink(path: String, target: String)
    /// Replace a symlink with an independent copy of the directory it
    /// resolves to.
    case materialize(String)
    /// Delete a leftover host skills folder that holds only links, then its
    /// parent when nothing but Finder noise remains there.
    case removeLeftoverSkillsDir(String)
    /// ADR-0008's confirmed local-plugin disable exception.
    case movePlugin(path: String, destination: String)
    case replaceHookSource(path: String, hash: String, contents: String)
    case deleteHookHelper(path: String, hash: String)
    case deleteAgentExtension(path: String, hash: String)
    case removeHermesPlugin(path: String, hash: String, name: String)
    /// ADR-0014 rule 2 for add-ons: JSON-encoded `AgentConfigEdit`s on one host file.
    case editAgentConfig(path: String, hash: String, edits: String)
    /// Moves an Amp or OpenCode entry out of discovery (disable) or back (enable).
    case moveAgentExtension(path: String, hash: String, destination: String)
    /// ADR-0014 rule 2: replace a Codex `config.toml` whose only change is the
    /// reviewed plugin's `enabled` value, re-verified against the scanned hash.
    case replaceConfigSource(
        path: String, hash: String, contents: String, pluginID: String, enabled: Bool)

    static let executable = "sukiru-fileop"

    public init?(argv: [String]) {
        guard argv.first == Self.executable, argv.count >= 3 else {
            return nil
        }
        switch (argv[1], argv.count) {
        case ("replace-hook-source", 5), ("delete-hook-helper", 4), ("replace-config-source", 7),
            ("delete-agent-extension", 4), ("remove-hermes-plugin", 5), ("edit-agent-config", 5),
            ("move-agent-extension", 5):
            guard let operation = Self.sourceOperation(argv) else { return nil }
            self = operation
        case ("delete-directory", 3):
            self = .deleteDirectory(argv[2])
        case ("delete-link", 3):
            self = .deleteLink(argv[2])
        case ("relink", 4):
            self = .relink(path: argv[2], target: argv[3])
        case ("materialize", 3):
            self = .materialize(argv[2])
        case ("remove-leftover-skills-dir", 3):
            self = .removeLeftoverSkillsDir(argv[2])
        case ("move-plugin", 4):
            self = .movePlugin(path: argv[2], destination: argv[3])
        default:
            return nil
        }
    }

    /// The hook and config source edits, which carry a scanned content hash.
    private static func sourceOperation(_ argv: [String]) -> FileOperation? {
        switch argv[1] {
        case "replace-hook-source":
            .replaceHookSource(path: argv[2], hash: argv[3], contents: argv[4])
        case "delete-hook-helper":
            .deleteHookHelper(path: argv[2], hash: argv[3])
        case "delete-agent-extension":
            .deleteAgentExtension(path: argv[2], hash: argv[3])
        case "remove-hermes-plugin":
            .removeHermesPlugin(path: argv[2], hash: argv[3], name: argv[4])
        case "edit-agent-config":
            .editAgentConfig(path: argv[2], hash: argv[3], edits: argv[4])
        case "move-agent-extension":
            .moveAgentExtension(path: argv[2], hash: argv[3], destination: argv[4])
        case "replace-config-source" where ["true", "false"].contains(argv[6]):
            .replaceConfigSource(
                path: argv[2], hash: argv[3], contents: argv[4], pluginID: argv[5],
                enabled: argv[6] == "true")
        default:
            nil
        }
    }

    var argv: [String] {
        switch self {
        case .replaceHookSource(let path, let hash, let contents):
            return [Self.executable, "replace-hook-source", path, hash, contents]
        case .deleteHookHelper(let path, let hash):
            return [Self.executable, "delete-hook-helper", path, hash]
        case .deleteAgentExtension(let path, let hash):
            return [Self.executable, "delete-agent-extension", path, hash]
        case .removeHermesPlugin(let path, let hash, let name):
            return [Self.executable, "remove-hermes-plugin", path, hash, name]
        case .editAgentConfig(let path, let hash, let edits):
            return [Self.executable, "edit-agent-config", path, hash, edits]
        case .moveAgentExtension(let path, let hash, let destination):
            return [Self.executable, "move-agent-extension", path, hash, destination]
        case .replaceConfigSource(let path, let hash, let contents, let pluginID, let enabled):
            return [
                Self.executable, "replace-config-source", path, hash, contents, pluginID,
                String(enabled)
            ]
        case .deleteDirectory(let path):
            return [Self.executable, "delete-directory", path]
        case .deleteLink(let path):
            return [Self.executable, "delete-link", path]
        case .relink(let path, let target):
            return [Self.executable, "relink", path, target]
        case .materialize(let path):
            return [Self.executable, "materialize", path]
        case .removeLeftoverSkillsDir(let path):
            return [Self.executable, "remove-leftover-skills-dir", path]
        case .movePlugin(let path, let destination):
            return [Self.executable, "move-plugin", path, destination]
        }
    }

    /// Every path the operation reads or writes (workspace-boundary check).
    var paths: [String] {
        switch self {
        case .replaceHookSource(let path, _, _), .deleteHookHelper(let path, _),
            .replaceConfigSource(let path, _, _, _, _), .deleteAgentExtension(let path, _),
            .removeHermesPlugin(let path, _, _), .editAgentConfig(let path, _, _):
            [path]
        case .moveAgentExtension(let path, _, let destination): [path, destination]
        default: Array(argv.dropFirst(2))
        }
    }

    func perform(environment: SukiruEnvironment? = nil) throws {
        let fileManager = FileManager.default
        let probe = DefaultFileSystemProbe()
        switch self {
        case .replaceHookSource, .deleteHookHelper, .replaceConfigSource, .deleteAgentExtension,
            .removeHermesPlugin, .editAgentConfig, .moveAgentExtension:
            try performSourceEdit(environment: environment)
        case .deleteDirectory(let path):
            try fileManager.removeItem(atPath: path)
        case .deleteLink(let path):
            try Self.deleteLink(path, probe: probe)
        case .relink(let path, let target):
            try Self.relink(path, to: target, probe: probe)
        case .materialize(let path):
            guard case .symlink? = probe.entryKind(atPath: path),
                let resolved = probe.resolvedPath(atPath: path),
                probe.isDirectory(atPath: resolved)
            else {
                throw FileOperationError("'\(path)' is not a link to a skill directory")
            }
            try Self.replace(path) {
                try fileManager.copyItem(atPath: resolved, toPath: path)
            }
        case .removeLeftoverSkillsDir(let path):
            try Self.removeLeftoverSkillsDir(path, probe: probe)
        case .movePlugin(let path, let destination):
            try Self.movePlugin(path, destination: destination, environment: environment)
        }
    }

    private func performSourceEdit(environment: SukiruEnvironment?) throws {
        switch self {
        case .replaceHookSource(let path, let hash, let contents):
            try HookFileMutation.replace(path: path, hash: hash, contents: contents)
        case .deleteHookHelper(let path, let hash):
            try HookFileMutation.deleteHelper(
                path: path, hash: hash, environment: Self.scope(environment))
        case .deleteAgentExtension(let path, let hash):
            try AgentExtensionMutation.delete(
                path: path, hash: hash, environment: Self.scope(environment))
        case .removeHermesPlugin(let path, let hash, let name):
            try AgentExtensionMutation.removeHermesPlugin(
                path: path, hash: hash, name: name, environment: Self.scope(environment))
        case .editAgentConfig(let path, let hash, let edits):
            try AgentExtensionMutation.edit(path: path, hash: hash, edits: edits)
        case .moveAgentExtension(let path, let hash, let destination):
            try AgentExtensionMutation.move(
                path: path, hash: hash, destination: destination,
                environment: Self.scope(environment))
        case .replaceConfigSource(let path, let hash, let contents, let pluginID, let enabled):
            try CodexPluginEnablement.replace(
                path: path, hash: hash, contents: contents, pluginID: pluginID, enabled: enabled)
        default:
            break
        }
    }

    /// Hook and extension edits stay inside the inventory's scoped home.
    private static func scope(_ environment: SukiruEnvironment?) throws -> SukiruEnvironment {
        guard let environment else { throw HookError("This change requires a scoped inventory") }
        return environment
    }

    private static func deleteLink(_ path: String, probe: DefaultFileSystemProbe) throws {
        switch probe.entryKind(atPath: path) {
        case nil: return
        case .symlink?: try FileManager.default.removeItem(atPath: path)
        default: throw FileOperationError("'\(path)' is not a symlink; refusing to delete it")
        }
    }

    private static func movePlugin(
        _ path: String, destination: String, environment: SukiruEnvironment?
    ) throws {
        if DefaultFileSystemProbe().entryKind(atPath: path) == .directory, let environment {
            try CursorLocalDisable.validate(
                path: path, destination: destination, environment: environment)
            try moveOutsideDiscovery(path, destination: destination)
        } else {
            try movePlugin(path, destination: destination)
        }
    }

    private static func movePlugin(_ path: String, destination: String) throws {
        guard PluginLocalDisable.hasLegacyDefinition(at: path) else {
            throw FileOperationError(
                "The local plugin definition changed; inspect it again before disabling")
        }
        try moveOutsideDiscovery(path, destination: destination)
    }

    private static func moveOutsideDiscovery(_ path: String, destination: String) throws {
        let discovery = URL(fileURLWithPath: path).deletingLastPathComponent()
            .resolvingSymlinksInPath().path
        let resolvedDestination = URL(fileURLWithPath: destination).resolvingSymlinksInPath().path
        guard !resolvedDestination.hasPrefix(discovery + "/") else {
            throw FileOperationError("The disabled destination resolves inside plugin discovery")
        }
        let parent = URL(fileURLWithPath: destination).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: path, toPath: destination)
    }

    /// Re-checks at run time that the folder still holds only links, so a
    /// copy added since the scan is never deleted. The parent goes too when
    /// it is left empty: an empty host config folder reads as an installed
    /// agent to host detection.
    private static func removeLeftoverSkillsDir(
        _ path: String, probe: DefaultFileSystemProbe
    ) throws {
        guard LeftoverHostRule.linkCount(in: path, fileSystem: probe) != nil else {
            throw FileOperationError("'\(path)' holds more than links; refusing to delete it")
        }
        let fileManager = FileManager.default
        try fileManager.removeItem(atPath: path)
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard parent != "/", parent != NSHomeDirectory(),
            let rest = probe.directoryEntries(atPath: parent),
            rest.allSatisfy(LeftoverHostRule.finderNoise.contains)
        else { return }
        try fileManager.removeItem(atPath: parent)
    }

    private static func relink(
        _ path: String, to target: String, probe: DefaultFileSystemProbe
    ) throws {
        switch probe.entryKind(atPath: path) {
        case .directory?, .symlink?:
            break
        default:
            throw FileOperationError("'\(path)' is neither a copy nor a link")
        }
        guard probe.isDirectory(atPath: target) else {
            throw FileOperationError("link target '\(target)' is not a directory")
        }
        try replace(path) {
            try FileManager.default.createSymbolicLink(
                atPath: path, withDestinationPath: target)
        }
    }

    /// Moves `path` aside, creates its replacement, then drops the original;
    /// a failed replacement puts the original back.
    private static func replace(_ path: String, with create: () throws -> Void) throws {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: path)
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).sukiru-\(UUID().uuidString)").path
        try fileManager.moveItem(atPath: path, toPath: aside)
        do {
            try create()
        } catch {
            try? fileManager.removeItem(atPath: path)
            try? fileManager.moveItem(atPath: aside, toPath: path)
            throw error
        }
        try fileManager.removeItem(atPath: aside)
    }
}

struct FileOperationError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
