import Foundation

extension PluginInventoryReader {
    /// Cached manifests describe a catalog, not its current registration or scope.
    func cursorCatalogs(issues: inout [Issue]) -> [PluginMarketplace] {
        let root = HostPathResolver.join(environment.home, ".cursor/plugins/marketplaces")
        guard FileManager.default.fileExists(atPath: root) else { return [] }
        var readErrors: [Issue] = []
        let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil,
            errorHandler: { url, error in
                readErrors.append(
                    Issue(
                        kind: "plugin-config", path: url.path, message: error.localizedDescription))
                return true
            })
        var result: [PluginMarketplace] = []
        while let file = enumerator?.nextObject() as? URL {
            guard file.path.hasSuffix("/.cursor-plugin/marketplace.json"),
                cursorContained(file.path, in: root),
                let manifest = json(file.path, issues: &issues)
            else { continue }
            guard let name = manifest["name"] as? String,
                let entries = manifest["plugins"] as? [[String: Any]]
            else {
                issues.append(
                    Issue(
                        kind: "plugin-manifest", path: file.path,
                        message: "Cursor marketplace requires a name and plugin entries"))
                continue
            }
            let payload = file.deletingLastPathComponent().deletingLastPathComponent().path
            let plugins = cursorEntries(entries, manifestPath: file.path, issues: &issues)
            result.append(
                PluginMarketplace(
                    host: .cursor, name: name, source: payload, scopeRoot: environment.home,
                    path: payload, plugins: plugins, evidence: "cached-catalog"))
        }
        issues += readErrors
        return result
    }
    private func cursorEntries(
        _ entries: [[String: Any]], manifestPath: String, issues: inout [Issue]
    ) -> [PluginCatalogEntry] {
        entries.compactMap { entry -> PluginCatalogEntry? in
            let source: String?
            if let path = entry["source"] as? String {
                source = path
            } else {
                source = (entry["source"] as? [String: Any])?["path"] as? String
            }
            guard let name = entry["name"] as? String, let source else {
                issues.append(
                    Issue(
                        kind: "plugin-manifest", path: manifestPath,
                        message: "Cursor catalog entry requires a name and source path"))
                return nil
            }
            return PluginCatalogEntry(
                name: name, source: source, version: entry["version"] as? String)
        }
    }

}
