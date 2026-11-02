import Foundation

extension PluginInventoryReader {
    /// Cursor accepts a repository whose marketplace manifest lives in any of these locations.
    /// Order is precedence: one payload yields one catalog, not one per file.
    private static let cursorCatalogFiles = [
        ".cursor-plugin/marketplace.json", ".claude-plugin/marketplace.json",
        ".agents/plugins/marketplace.json"
    ]

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
        var catalogFiles: [String: (manifest: String, rank: Int)] = [:]
        while let file = enumerator?.nextObject() as? URL {
            guard cursorContained(file.path, in: root),
                let rank = Self.cursorCatalogFiles.firstIndex(where: {
                    file.path.hasSuffix("/" + $0)
                })
            else { continue }
            let payload = String(file.path.dropLast(Self.cursorCatalogFiles[rank].count + 1))
            if let found = catalogFiles[payload], found.rank <= rank { continue }
            catalogFiles[payload] = (file.path, rank)
        }
        var result: [PluginMarketplace] = []
        for (payload, catalog) in catalogFiles.sorted(by: { $0.key < $1.key }) {
            guard let manifest = json(catalog.manifest, issues: &issues) else { continue }
            guard let name = manifest["name"] as? String,
                let entries = manifest["plugins"] as? [Any]
            else {
                issues.append(
                    Issue(
                        kind: "plugin-manifest", path: catalog.manifest,
                        message: "Cursor marketplace requires a name and plugin entries"))
                continue
            }
            let plugins = cursorEntries(
                entries, manifestPath: catalog.manifest, root: payload, issues: &issues)
            result.append(
                PluginMarketplace(
                    host: .cursor, name: name, source: payload, scopeRoot: environment.home,
                    path: payload, plugins: plugins, evidence: "cached-catalog",
                    ref: manifest["gitRef"] as? String ?? manifest["ref"] as? String))
        }
        issues += readErrors
        return result
    }

    /// Sources and logos resolve from the payload root, the directory that holds the
    /// catalog file's `.cursor-plugin`/`.claude-plugin`/`.agents` parent.
    private func cursorEntries(
        _ entries: [Any], manifestPath: String, root: String, issues: inout [Issue]
    ) -> [PluginCatalogEntry] {
        entries.compactMap { value -> PluginCatalogEntry? in
            guard let entry = value as? [String: Any] else {
                issues.append(
                    Issue(
                        kind: "plugin-manifest", path: manifestPath,
                        message: "Cursor catalog entry requires a name and source path"))
                return nil
            }
            let source: String?
            if let path = entry["source"] as? String {
                source = path.isEmpty ? nil : path
            } else if let object = entry["source"] as? [String: Any] {
                source = object["path"] as? String ?? Self.claudeSourceLabel(object)
            } else {
                source = nil
            }
            guard let name = entry["name"] as? String, !name.isEmpty,
                let source, !source.isEmpty
            else {
                issues.append(
                    Issue(
                        kind: "plugin-manifest", path: manifestPath,
                        message: "Cursor catalog entry requires a name and source path"))
                return nil
            }
            var listing = PluginCatalogEntry(
                name: name, source: source, version: entry["version"] as? String)
            listing.summary = entry["description"] as? String
            listing.author = (entry["author"] as? [String: Any])?["name"] as? String
            listing.homepage = entry["homepage"] as? String
            listing.repository = entry["repository"] as? String
            listing.license = entry["license"] as? String
            listing.categories = (entry["category"] as? String).map { [$0] }
            listing.keywords =
                (entry["keywords"] as? [String] ?? [])
                + (entry["tags"] as? [String] ?? [])
            if let logo = entry["logo"] as? String {
                let path = HostPathResolver.join(root, logo)
                if logo.hasPrefix("https://") {
                    listing.logo = logo
                } else if !logo.hasPrefix("/"), cursorContained(path, in: root) {
                    listing.logo = path
                }
            }
            return listing
        }
    }

}
