import Foundation

extension PluginInventoryReader {
    func readOpenCode(
        roots: [String], scope: Scope, issues: inout [Issue]
    ) -> [PluginInstallation] {
        let global = openCodeGlobalConfigDirectory()
        let custom = environment.externalValue(for: "OPENCODE_CONFIG")
        let inline = environment.externalValue(for: "OPENCODE_CONFIG_CONTENT")
        let scopes = openCodeScopes(
            roots: roots, scope: scope, global: global, custom: custom, inline: inline)
        return scopes.flatMap { readOpenCodeScope($0, issues: &issues) }
            .sorted { $0.id < $1.id }
    }

    private func openCodeGlobalConfigDirectory() -> String {
        environment.externalValue(for: "OPENCODE_CONFIG_DIR")
            ?? HostPathResolver.join(
                environment.xdgConfigHome
                    ?? environment.externalValue(for: "XDG_CONFIG_HOME")
                    ?? HostPathResolver.join(environment.home, ".config"), "opencode")
    }

    private func openCodeScopes(
        roots: [String], scope: Scope, global: String, custom: String?, inline: String?
    ) -> [OpenCodeScope] {
        var result: [OpenCodeScope] = []
        if scope.includes(.user) {
            result.append(
                OpenCodeScope(
                    root: environment.home,
                    layers: [
                        OpenCodeLayer(
                            directory: global,
                            files: ["opencode.json", "opencode.jsonc", "config.json", "cli.json"]),
                        custom.map(OpenCodeLayer.init(path:)),
                        inline.map { OpenCodeLayer(text: $0, directory: environment.home) }
                    ].compactMap { $0 },
                    discovery: [global]))
        }
        if scope.includes(.project) {
            result += roots.map { root in
                OpenCodeScope(
                    root: root,
                    layers: [
                        custom.map(OpenCodeLayer.init(path:)),
                        OpenCodeLayer(directory: root, files: ["opencode.json", "opencode.jsonc"]),
                        OpenCodeLayer(
                            directory: HostPathResolver.join(root, ".opencode"),
                            files: ["opencode.json", "opencode.jsonc", "cli.json"]),
                        inline.map { OpenCodeLayer(text: $0, directory: root) }
                    ].compactMap { $0 },
                    discovery: [HostPathResolver.join(root, ".opencode")])
            }
        }
        return result
    }

    private func readOpenCodeScope(
        _ scope: OpenCodeScope, issues: inout [Issue]
    ) -> [PluginInstallation] {
        var configured: [String: PluginInstallation] = [:]
        for layer in scope.layers {
            for (file, object) in openCodeObjects(in: layer, issues: &issues) {
                let plugins = configuredPlugins(
                    in: object, file: file, layer: layer, scopeRoot: scope.root,
                    issues: &issues)
                for plugin in plugins {
                    configured[plugin.id] = plugin
                }
            }
        }
        for directory in scope.discovery {
            for plugin in openCodeLocal(directory, root: scope.root)
            where configured[plugin.id] == nil {
                configured[plugin.id] = plugin
            }
        }
        return Array(configured.values)
    }

    private func openCodeObjects(
        in layer: OpenCodeLayer, issues: inout [Issue]
    ) -> [(String, [String: Any])] {
        if let path = layer.path {
            guard let object = json(path, issues: &issues) else { return [] }
            return [(URL(fileURLWithPath: path).lastPathComponent, object)]
        }
        if let text = layer.text {
            guard let object = json(text: text, source: "OPENCODE_CONFIG_CONTENT", issues: &issues)
            else { return [] }
            return [("opencode.jsonc", object)]
        }
        return layer.files.compactMap { file in
            guard
                let object = json(
                    HostPathResolver.join(layer.directory, file), issues: &issues)
            else { return nil }
            return (file, object)
        }
    }

    private func configuredPlugins(
        in object: [String: Any], file: String, layer: OpenCodeLayer, scopeRoot: String,
        issues: inout [Issue]
    ) -> [PluginInstallation] {
        ["plugin", "plugins"].flatMap { key in
            packages(in: object[key])
                .filter { !isControlDirective($0) }
                .map { package in
                    let path = localPath(package, relativeTo: layer.directory, issues: &issues)
                    return PluginInstallation(
                        host: .opencode, source: package, identifier: package,
                        scope: scopeRoot == environment.home ? "user" : "project",
                        scopeRoot: scopeRoot, version: nil, path: path,
                        enablement: .enabled, loadStatus: "unknown",
                        components: [
                            PluginComponent(
                                kind: componentKind(file: file, key: key), name: package, path: path
                            )
                        ], installationStatus: "configured")
                }
        }
    }

    private func componentKind(file: String, key: String) -> String {
        if file == "cli.json" { return "cli" }
        return key == "plugin" ? "v1" : "server"
    }

    private struct OpenCodeScope {
        let root: String
        let layers: [OpenCodeLayer]
        let discovery: [String]
    }

    private struct OpenCodeLayer {
        let path: String?
        let text: String?
        let directory: String
        let files: [String]

        init(directory: String, files: [String]) {
            self.path = nil
            self.text = nil
            self.directory = directory
            self.files = files
        }

        init(path: String) {
            self.path = path
            self.text = nil
            self.directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
            self.files = []
        }

        init(text: String, directory: String) {
            self.path = nil
            self.text = text
            self.directory = directory
            self.files = []
        }
    }

    private func packages(in value: Any?) -> [String] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap { value in
            if let package = value as? String { return package }
            if let object = value as? [String: Any] { return object["package"] as? String }
            return nil
        }
    }

    private func isControlDirective(_ package: String) -> Bool {
        package == "*" || package == ".*" || package.hasPrefix("-")
    }

    private func localPath(
        _ package: String, relativeTo directory: String, issues: inout [Issue]
    ) -> String? {
        if package.hasPrefix("file:") {
            guard let components = URLComponents(string: package),
                components.scheme?.lowercased() == "file",
                components.host == nil || components.host?.isEmpty == true
                    || components.host?.lowercased() == "localhost",
                components.query == nil, components.fragment == nil,
                let path = components.percentEncodedPath.removingPercentEncoding,
                path.hasPrefix("/"), !path.contains("\0")
            else {
                issues.append(
                    Issue(
                        kind: "plugin-config", path: package,
                        message: "Expected a local absolute file URL"))
                return nil
            }
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        guard package.hasPrefix(".") || package.hasPrefix("/") else { return nil }
        return resolvePluginPath(package, relativeTo: directory)
    }

    private func openCodeLocal(_ directory: String, root: String) -> [PluginInstallation] {
        ["plugin", "plugins"].flatMap { name in
            let container = HostPathResolver.join(directory, name)
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: container)) ?? []
            return entries.sorted().compactMap { entry -> PluginInstallation? in
                guard !entry.hasPrefix(".") else { return nil }
                let path = HostPathResolver.join(container, entry)
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                guard exists,
                    isDirectory.boolValue || entry.hasSuffix(".ts") || entry.hasSuffix(".js")
                else {
                    return nil
                }
                return PluginInstallation(
                    host: .opencode, source: path, identifier: entry,
                    scope: root == environment.home ? "user" : "project", scopeRoot: root,
                    version: nil, path: path, enablement: .unknown, loadStatus: "unknown",
                    components: [PluginComponent(kind: "local", name: entry, path: path)],
                    installationStatus: "discovered")
            }
        }
    }
}

extension PluginInventoryReader {
    func json(text: String, source: String, issues: inout [Issue]) -> [String: Any]? {
        do {
            let input = PluginJSONC.data(text)
            guard let object = try JSONSerialization.jsonObject(with: input) as? [String: Any]
            else {
                issues.append(
                    Issue(kind: "plugin-config", path: source, message: "Expected a JSON object"))
                return nil
            }
            return object
        } catch {
            issues.append(
                Issue(kind: "plugin-config", path: source, message: error.localizedDescription))
            return nil
        }
    }
}
