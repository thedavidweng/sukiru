import Foundation

extension PluginLifecyclePlanner {
    func validate(_ request: PluginLifecycleRequest) throws {
        guard PluginLifecycleRequest.actions.contains(request.action), !request.target.isEmpty,
            request.target != "*"
                || (request.host == .opencode
                    && ["list", "check", "update"].contains(request.action))
                || (request.host == .antigravity && ["list", "import"].contains(request.action)),
            !request.target.hasPrefix("-")
                || (request.host == .antigravity
                    && request.target.range(of: #"^-\d+$"#, options: .regularExpression) != nil),
            request.target.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else { throw PluginLifecycleError(message: "Invalid plugin action or target") }
        if request.marketplace != nil || request.strict != nil {
            guard request.host == .antigravity,
                request.marketplace == nil || request.action == "link",
                request.strict == nil || request.action == "validate"
            else {
                throw PluginLifecycleError(
                    message:
                        "Marketplace and strict options apply to Antigravity link and validate only"
                )
            }
        }
        if let gitRef = request.gitRef {
            guard request.host == .cursor, request.action == "marketplace-add",
                Self.isValidCursorGitRef(gitRef)
            else {
                throw PluginLifecycleError(
                    message: "Cursor marketplace Git ref must be a single non-empty ref argument")
            }
        }
        let managedUpdate =
            request.host == .claude && request.action == "update" && request.scope == "managed"
        guard ["user", "project", "local"].contains(request.scope) || managedUpdate,
            request.scope == "user" || managedUpdate
                ? request.scopeRoot == environment.home
                : environment.projectRoots.contains(request.scopeRoot)
        else {
            throw PluginLifecycleError(
                message: "Scope must identify the user home or an added project")
        }
    }

    private static func isValidCursorGitRef(_ ref: String) -> Bool {
        !ref.isEmpty && !ref.hasPrefix("-") && ref.allSatisfy { !$0.isWhitespace }
            && ref.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

}
