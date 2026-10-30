import Foundation

/// The sources `agy plugin install` accepts. agy 1.4.11 rejects a bare plugin name,
/// even for the official catalog, so a marketplace install always names its marketplace.
enum AntigravityInstallTarget: Equatable {
    case marketplace(plugin: String, marketplace: String)
    /// A normalized `https://github.com/<owner>/<repo>` URL; agy clones its default branch.
    case repository(String)
    case directory(String)

    init(_ target: String) throws {
        if target.hasPrefix("/") || target.hasPrefix(".") {
            self = .directory(target)
        } else if target.contains("/") || target.contains(":") {
            guard let repo = try? InstallPlanBuilder.ownerRepo(fromSource: target) else {
                throw PluginLifecycleError(
                    message:
                        "Antigravity repository installs accept GitHub repositories only: "
                        + "owner/repo or a github.com URL")
            }
            self = .repository("https://github.com/" + repo)
        } else {
            let parts = target.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw PluginLifecycleError(
                    message:
                        "Antigravity installs need <plugin>@<marketplace>, "
                        + "a GitHub repository, or a local directory path")
            }
            self = .marketplace(plugin: String(parts[0]), marketplace: String(parts[1]))
        }
    }

    var argument: String {
        switch self {
        case .marketplace(let plugin, let marketplace): "\(plugin)@\(marketplace)"
        case .repository(let url): url
        case .directory(let path): path
        }
    }
}
