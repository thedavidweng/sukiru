import Foundation

extension PluginInventoryReader {
    private static let pluginManifests = [
        ".codex-plugin/plugin.json", ".claude-plugin/plugin.json", ".cursor-plugin/plugin.json",
        ".factory-plugin/plugin.json"
    ]

    /// Catalogs often list only a name and a path. A plugin inside the marketplace checkout
    /// describes itself in its own manifest, and a checkout of a GitHub repository locates
    /// its source there. What the catalog declares always wins.
    func withPluginDetails(_ marketplace: PluginMarketplace) -> PluginMarketplace {
        guard marketplace.host != .antigravity, let root = marketplace.path else {
            return marketplace
        }
        let repository = Self.githubRepository(marketplace)
        var result = marketplace
        result.plugins = marketplace.plugins.map { entry in
            guard let (directory, relative) = Self.pluginDirectory(entry.source, in: root) else {
                return entry
            }
            var listing = entry
            var ignored: [Issue] = []
            let manifest = Self.pluginManifests.lazy
                .map { HostPathResolver.join(directory, $0) }
                .first { FileManager.default.fileExists(atPath: $0) }
                .flatMap { json($0, issues: &ignored) }
            if let manifest {
                let interface = manifest["interface"] as? [String: Any]
                let details = PluginManifestDetails(manifest, root: directory)
                listing.displayName =
                    listing.displayName ?? interface?["displayName"] as? String
                    ?? manifest["displayName"] as? String
                listing.summary = listing.summary ?? details.summary
                listing.logo = listing.logo ?? details.logo
                listing.author =
                    listing.author ?? (manifest["author"] as? [String: Any])?["name"] as? String
                    ?? manifest["author"] as? String ?? interface?["developerName"] as? String
                listing.homepage =
                    listing.homepage ?? manifest["homepage"] as? String
                    ?? interface?["websiteURL"] as? String
                listing.repository = listing.repository ?? manifest["repository"] as? String
                listing.license = listing.license ?? manifest["license"] as? String
                listing.keywords = listing.keywords ?? manifest["keywords"] as? [String]
            }
            if listing.repository == nil, let repository {
                let path = relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                listing.repository =
                    "https://github.com/" + repository
                    + (relative.isEmpty
                        ? "" : "/tree/\(marketplace.ref ?? "HEAD")/\(path ?? relative)")
            }
            return listing
        }
        return result
    }

    /// A checkout's root is its repository root, except for Droid's `git-subdir`, which
    /// checks out a subdirectory.
    private static func githubRepository(_ marketplace: PluginMarketplace) -> String? {
        guard !marketplace.localSource, marketplace.sourceType != "git-subdir" else { return nil }
        return try? InstallPlanBuilder.ownerRepo(fromSource: marketplace.source)
    }

    /// A relative listing source that resolves to a directory inside the marketplace.
    private static func pluginDirectory(
        _ source: String, in root: String
    ) -> (path: String, relative: String)? {
        guard !source.contains(":"), !source.hasPrefix("/"), source != "inline" else { return nil }
        let boundary = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
            .path
        let path = URL(fileURLWithPath: boundary).appendingPathComponent(source)
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard path == boundary || path.hasPrefix(boundary + "/"),
            DefaultFileSystemProbe().isDirectory(atPath: path)
        else { return nil }
        return (path, String(path.dropFirst(boundary.count)).trimmingCharacters(in: ["/"]))
    }
}
