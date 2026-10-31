import Foundation

extension PluginInventoryReader {
    /// App and CLI share preferences; directory names, not manifest names, are their keys.
    func readAntigravity(
        roots: [String], scope: Scope, issues: inout [Issue]
    ) -> [PluginInstallation] {
        let config = HostPathResolver.join(environment.home, ".gemini/config")
        let settingsPath = HostPathResolver.join(config, "config.json")
        let settings = json(settingsPath, issues: &issues, jsonc: true)
        let preferences = settings?["plugins"] as? [String: Any] ?? [:]
        let validSettings =
            !issues.contains { $0.path == settingsPath }
            && (settings?["plugins"] == nil || settings?["plugins"] is [String: Any])
        if !validSettings, !issues.contains(where: { $0.path == settingsPath }) {
            issues.append(
                Issue(
                    kind: "plugin-config", path: settingsPath,
                    message: "Antigravity plugins preferences must be an object"))
        }
        var result: [PluginInstallation] = []
        var visited = Set<String>()
        let locations = antigravityLocations(roots: roots, scope: scope)
        for (location, root) in locations {
            let direct = HostPathResolver.join(location, "plugins")
            var discoveries = antigravityDirectories(direct, issues: &issues).map { ($0, direct) }
            var configs = Set<String>()
            discoveries += antigravityConfiguredPlugins(
                HostPathResolver.join(location, "plugins.json"),
                relativeTo: root, visited: &configs, issues: &issues)
            for (path, source) in discoveries {
                guard visited.insert(root + "\n" + path).inserted else { continue }
                let plugin = antigravityInstallation(
                    path, source: source, root: root,
                    preferences: validSettings ? preferences : nil, issues: &issues)
                if let plugin { result.append(plugin) }
            }
        }
        return result
    }

    private func antigravityInstallation(
        _ path: String, source: String, root: String,
        preferences: [String: Any]?, issues: inout [Issue]
    ) -> PluginInstallation? {
        guard let manifestPath = antigravityManifest(path, issues: &issues),
            antigravityContained(manifestPath, root: path, issues: &issues),
            let manifest = json(manifestPath, issues: &issues, jsonc: true)
        else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let preference = preferences?[name] as? [String: Any]
        let configured = preference?["enabled"] as? Bool
        let disabled = manifest["disabled"] as? Bool
        let valid =
            preferences != nil
            && (preferences?[name] == nil || preference != nil)
            && (preference?["enabled"] == nil || configured != nil)
            && (manifest["disabled"] == nil || disabled != nil)
        if !valid {
            issues.append(
                Issue(
                    kind: "plugin-config", path: path,
                    message: "Unrecognized Antigravity plugin enablement; use agy plugin validate"))
        }
        return PluginInstallation(
            host: .antigravity, source: source, identifier: name,
            scope: root == environment.home ? "user" : "project", scopeRoot: root,
            version: manifest["version"] as? String, path: path,
            enablement: valid
                ? ((configured ?? !(disabled ?? false)) ? .enabled : .disabled) : .unknown,
            loadStatus: "unknown",
            components: antigravityComponents(
                path, manifest: manifest, manifestPath: manifestPath, issues: &issues),
            installationStatus: "discovered",
            name: manifest["displayName"] as? String
                ?? manifest["name"] as? String,
            details: PluginManifestDetails(manifest, root: path))
    }

    private func antigravityLocations(roots: [String], scope: Scope) -> [(String, String)] {
        let userLocations = [
            ".gemini/config", ".gemini/antigravity-cli", ".gemini/antigravity-cli/builtin",
            ".gemini/antigravity/builtin"
        ]
        var result: [(String, String)] = []
        if scope.includes(.user) {
            result += userLocations.map {
                (HostPathResolver.join(environment.home, $0), environment.home)
            }
        }
        if scope.includes(.project) {
            result += roots.flatMap { root in antigravityProjectLocations(root).map { ($0, root) } }
        }
        return result
    }

    func antigravityProjectLocations(_ root: String) -> [String] {
        var directory = URL(fileURLWithPath: root).standardizedFileURL
        var ancestors = [directory]
        while directory.path != "/" {
            let marker = directory.appendingPathComponent(".git").path
            if FileManager.default.fileExists(atPath: marker) {
                return ancestors.map { $0.appendingPathComponent(".agents").path }
            }
            directory.deleteLastPathComponent()
            ancestors.append(directory)
        }
        return [HostPathResolver.join(root, ".agents")]
    }

    private func antigravityManifest(_ root: String, issues: inout [Issue]) -> String? {
        for marker in ["", ".antigravity-plugin", ".gemini-plugin"] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else {
                return nil
            }
            let directory: String
            if marker.isEmpty {
                directory = root
            } else {
                guard let name = names.sorted().first(where: { $0.lowercased() == marker }) else {
                    continue
                }
                directory = HostPathResolver.join(root, name)
            }
            guard antigravityContained(directory, root: root, issues: &issues),
                let files = try? FileManager.default.contentsOfDirectory(atPath: directory),
                let file = files.sorted().first(where: { $0.lowercased() == "plugin.json" })
            else { continue }
            return HostPathResolver.join(directory, file)
        }
        return nil
    }

    func antigravityDirectories(_ directory: String, issues: inout [Issue]) -> [String] {
        guard FileManager.default.fileExists(atPath: directory) else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory)
                .filter { !$0.hasPrefix(".") }.sorted().map { HostPathResolver.join(directory, $0) }
                .filter { DefaultFileSystemProbe().isDirectory(atPath: $0) }
        } catch {
            issues.append(
                Issue(kind: "plugin-config", path: directory, message: error.localizedDescription))
            return []
        }
    }

    func antigravityContained(_ path: String, root: String, issues: inout [Issue]) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let boundary = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved == boundary || resolved.hasPrefix(boundary + "/") else {
            issues.append(
                Issue(
                    kind: "plugin-containment", path: path,
                    message: "Antigravity component resolves outside its plugin"))
            return false
        }
        return true
    }
}
