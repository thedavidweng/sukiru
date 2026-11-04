import Foundation

/// What `hermes plugins install` receives. A bare name is a curated catalog entry, which Hermes
/// resolves to the repository and commit SHA the catalog pins; anything else must be a GitHub
/// repository, which Hermes clones at its default branch.
enum HermesInstallTarget: Equatable {
    case catalog(String)
    case repository(String)

    init(_ target: String) throws {
        if HermesPluginName.isValid(target) {
            self = .catalog(target)
            return
        }
        guard let repo = try? InstallPlanBuilder.ownerRepo(fromSource: target) else {
            throw PluginLifecycleError(
                message: "Hermes installs need a catalog plugin name or a GitHub repository "
                    + "(owner/repo or a github.com URL)")
        }
        self = .repository("https://github.com/" + repo)
    }

    var argument: String {
        switch self {
        case .catalog(let name): name
        case .repository(let url): url
        }
    }
}

/// Hermes plugin names are directory and catalog keys. A leading `-` would read as an option.
enum HermesPluginName {
    static func isValid(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
    }
}
