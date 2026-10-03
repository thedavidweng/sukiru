import Foundation

/// Recognizes a definite v1 factory-only shape without importing plugin code.
/// Other definitions remain unknown; this is not a JavaScript validator.
public enum PluginLocalDisable {
    public static let migrationURL = "https://opencode.ai/v2/docs/build/plugins/migrate-v1"

    public static func hasLegacyDefinition(at path: String) -> Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        let code = PluginSourceInspection.code(text)
        guard
            code.range(
                of: #"\b(default|module\s*\.\s*exports|exports\s*\.)\b"#,
                options: .regularExpression) == nil
        else { return false }
        let factory = #"const\s+\w+(?:\s*:\s*\w+)?\s*=\s*async\s*\("#
        let pattern = #"(?m)^\s*export\s+(?:"# + factory + #"|async\s+function\s+\w+\s*\()"#
        return code.range(of: pattern, options: .regularExpression) != nil
    }

    public static func command(
        request: PluginLifecycleRequest, inventory: PluginInventory,
        environment: SukiruEnvironment, hostVersion: String
    ) throws -> BatchCommand {
        guard request.host == .opencode, hostVersion == "2.0.22",
            let plugin = inventory.installations.first(where: {
                $0.host == .opencode && $0.path == request.target
                    && $0.scopeRoot == request.scopeRoot
            }), let path = plugin.path, hasLegacyDefinition(at: path)
        else {
            throw PluginLifecycleError(
                message: "No verified v2-incompatible local definition at this path")
        }
        guard exclusivelyDiscovered(plugin, path: path, inventory: inventory) else {
            throw PluginLifecycleError(
                message:
                    "This file has an explicit or alternate discovery reference; "
                    + "use producer migration instructions"
            )
        }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        guard ["plugin", "plugins"].contains(parent.lastPathComponent),
            path.hasSuffix(".js") || path.hasSuffix(".ts")
        else {
            throw PluginLifecycleError(
                message: "Only directly auto-discovered local files can be disabled")
        }
        let discovery = parent.deletingLastPathComponent()
        guard discovery.path == discoveryRoot(request, environment: environment) else {
            throw PluginLifecycleError(
                message: "Local file is outside the selected discovery scope")
        }
        let container = discovery.appendingPathComponent("disabled-plugins").path
        let destination = URL(fileURLWithPath: container)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent).path
        try checkDestination(destination, inventory: inventory)
        let argv = ["sukiru-fileop", "move-plugin", path, destination]
        return BatchCommand(
            argv: argv, displayString: BatchCommand.display(for: argv), owningCLI: .file,
            intent:
                "Disable loading of a v1-style local plugin in OpenCode v2; behavior remains unavailable",
            dangerFlags: [.directFileOperation],
            warning:
                "Moves the local file outside discovery. This disables loading; it does not restore behavior. "
                + "Producer migration instructions: \(migrationURL). Author scripts are not executed.",
            workingDirectory: request.scopeRoot, captureRoots: [path, container])
    }

    private static func exclusivelyDiscovered(
        _ plugin: PluginInstallation, path: String, inventory: PluginInventory
    ) -> Bool {
        let physical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let referenced = inventory.installations.contains {
            guard $0.host == .opencode, let other = $0.path else { return false }
            return URL(fileURLWithPath: other).resolvingSymlinksInPath().path == physical
                && ($0.id != plugin.id || $0.installationStatus != "discovered")
        }
        return plugin.installationStatus == "discovered" && !referenced
    }

    private static func checkDestination(_ destination: String, inventory: PluginInventory) throws {
        let resolved = URL(fileURLWithPath: destination).resolvingSymlinksInPath().path
        let inside = inventory.installations.contains { plugin in
            guard plugin.host == .opencode, plugin.installationStatus == "discovered",
                let path = plugin.path
            else { return false }
            let root = URL(fileURLWithPath: path).deletingLastPathComponent()
                .resolvingSymlinksInPath().path
            return resolved == root || resolved.hasPrefix(root + "/")
        }
        if inside {
            throw PluginLifecycleError(
                message: "Disabled destination resolves inside plugin discovery")
        }
    }

    private static func discoveryRoot(
        _ request: PluginLifecycleRequest, environment: SukiruEnvironment
    ) -> String {
        if request.scopeRoot != environment.home {
            return HostPathResolver.join(request.scopeRoot, ".opencode")
        }
        return environment.externalValue(for: "OPENCODE_CONFIG_DIR")
            ?? HostPathResolver.join(
                environment.xdgConfigHome ?? environment.externalValue(for: "XDG_CONFIG_HOME")
                    ?? HostPathResolver.join(environment.home, ".config"), "opencode")
    }
}
