import Foundation

enum CursorLocalDisable {
    static func command(
        request: PluginLifecycleRequest, inventory: PluginInventory, environment: SukiruEnvironment
    ) throws -> BatchCommand {
        guard request.scope == "user",
            let plugin = inventory.installations.first(where: {
                $0.host == .cursor && $0.path == request.target && $0.scopeRoot == request.scopeRoot
                    && $0.installationStatus == "discovered"
            }), let path = plugin.path
        else {
            throw PluginLifecycleError(
                message: "Choose a discovered Cursor local plugin, not a marketplace/cache payload")
        }
        let root = HostPathResolver.join(environment.home, ".cursor/plugins")
        let container = HostPathResolver.join(root, "disabled-local")
        let destination = HostPathResolver.join(
            container, UUID().uuidString + "/" + URL(fileURLWithPath: path).lastPathComponent)
        try validate(path: path, destination: destination, environment: environment)
        let manifest = HostPathResolver.join(
            path, plugin.format == "cursor-plugin" ? ".cursor-plugin/plugin.json" : "plugin.json")
        let hash = HookInventoryReader.hash(try Data(contentsOf: URL(fileURLWithPath: manifest)))
        let argv = ["sukiru-fileop", "move-plugin", path, destination]
        return BatchCommand(
            argv: argv, displayString: BatchCommand.display(for: argv), owningCLI: .file,
            intent: "Disable Local Loading for Cursor: " + plugin.identifier,
            dangerFlags: [.directFileOperation],
            warning:
                "Moves this local development plugin outside Cursor's documented discovery root. "
                + "Local imports policy and marketplace precedence remain host-owned. "
                + "Snapshot rollback can restore the directory; no plugin code is executed.",
            captureRoots: [path, container],
            hookPreconditions: [HookFilePrecondition(path: manifest, contentHash: hash)])
    }

    static func validate(path: String, destination: String, environment: SukiruEnvironment) throws {
        let root = URL(fileURLWithPath: HostPathResolver.join(environment.home, ".cursor/plugins"))
        let local = root.appendingPathComponent("local").standardizedFileURL
        let source = URL(fileURLWithPath: path).standardizedFileURL
        let disabled = root.appendingPathComponent("disabled-local").resolvingSymlinksInPath().path
        let resolvedRoot = root.resolvingSymlinksInPath().path
        let resolvedSource = source.resolvingSymlinksInPath().path
        guard local.resolvingSymlinksInPath().path == resolvedRoot + "/local",
            source.deletingLastPathComponent() == local,
            DefaultFileSystemProbe().entryKind(atPath: path) == .directory,
            resolvedSource
                == local.resolvingSymlinksInPath().appendingPathComponent(source.lastPathComponent)
                .path,
            disabled == resolvedRoot + "/disabled-local",
            URL(fileURLWithPath: destination).resolvingSymlinksInPath().path.hasPrefix(
                disabled + "/"),
            URL(fileURLWithPath: destination).deletingLastPathComponent()
                .deletingLastPathComponent().path
                == root.appendingPathComponent("disabled-local").path
        else {
            throw PluginLifecycleError(
                message:
                    "Cursor local disable requires a physical plugin directly inside the documented local boundary "
                    + "and a destination outside discovery"
            )
        }
    }
}
