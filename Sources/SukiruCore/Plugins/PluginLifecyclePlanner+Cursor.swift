import Foundation

extension PluginLifecyclePlanner {
    func cursorCapabilities(
        probe: PluginLifecycleProbe, version: String
    ) throws -> PluginLifecycleCapabilities {
        var native: [String] = []
        var limits: [String: String] = [:]
        for action in PluginLifecycleRequest.actions where action != "disable-local" {
            let request = PluginLifecycleRequest(
                host: .cursor, action: action, target: "demo", scope: "user",
                scopeRoot: environment.home)
            if let limit = cursorLimitation(request) {
                limits[action] = limit
            } else {
                do {
                    try cursorHelp(action, probe: probe)
                    native.append(action)
                } catch { limits[action] = error.localizedDescription }
            }
        }
        return PluginLifecycleCapabilities(
            host: .cursor, version: version, nativeCandidates: native, limits: limits)
    }

    private func cursorHelp(_ action: String, probe: PluginLifecycleProbe) throws {
        let verb =
            action == "marketplace-refresh"
            ? "update" : String(action.dropFirst("marketplace-".count))
        try probe.help(
            host: .cursor, arguments: ["plugin", "marketplace", verb],
            requiredFlags: ["Usage:", "plugin marketplace " + verb])
        try probe.help(
            host: .cursor, arguments: ["plugin", "marketplace", "list"],
            requiredFlags: ["Usage:", "plugin marketplace list", "--format", "json"])
    }

    /// Registration targeting comes from an explicit official list request, not cache names.
    func cursorArguments(_ request: PluginLifecycleRequest) throws -> [String] {
        let probe = PluginLifecycleProbe(environment: environment)
        try cursorHelp(request.action, probe: probe)
        try cursorGitRefSupport(request, probe: probe)
        let verb =
            request.action == "marketplace-refresh"
            ? "update" : String(request.action.dropFirst("marketplace-".count))
        let output = try probe.output(
            host: .cursor, arguments: ["plugin", "marketplace", "list", "--format", "json"])
        let registrations = try cursorRegistrations(output)
        if verb == "add" {
            guard
                !registrations.contains(where: {
                    $0.name == request.target || $0.gitUrl == request.target
                })
            else {
                throw PluginLifecycleError(
                    message: "Cursor marketplace source is already registered")
            }
        } else {
            let matches = registrations.filter {
                $0.name == request.target || $0.gitUrl == request.target
            }
            guard matches.count == 1, let registration = matches.first else {
                throw PluginLifecycleError(
                    message: "Cursor marketplace is missing or ambiguous: " + request.target)
            }
            guard registration.scope == "user" else {
                throw PluginLifecycleError(
                    message:
                        "Cursor global/team marketplaces require Dashboard/Customize; no personal mutation is planned"
                )
            }
            // A URL alias shared by another registration is ambiguous even when the name is unique.
            guard
                registration.gitUrl.isEmpty
                    || registrations.filter({ $0.gitUrl == registration.gitUrl }).count == 1
            else {
                throw PluginLifecycleError(
                    message: "Cursor marketplace URL has duplicate registrations")
            }
        }
        var arguments = [
            PluginHost.cursor.executable, "plugin", "marketplace", verb, request.target
        ]
        if let gitRef = request.gitRef {
            arguments += ["--git-ref", gitRef]
        }
        return arguments
    }

    private func cursorGitRefSupport(
        _ request: PluginLifecycleRequest, probe: PluginLifecycleProbe
    ) throws {
        guard request.gitRef != nil else { return }
        try probe.help(
            host: .cursor, arguments: ["plugin", "marketplace", "add"],
            requiredFlags: ["--git-ref"])
    }

    private struct CursorRegistration: Decodable {
        let name: String
        let scope: String
        let gitUrl: String
    }

    private func cursorRegistrations(_ output: String) throws -> [CursorRegistration] {
        let registrations: [CursorRegistration]
        do {
            registrations = try JSONDecoder().decode(
                [CursorRegistration].self, from: Data(output.utf8))
        } catch {
            throw PluginLifecycleError(
                message: "Unrecognized Cursor marketplace JSON output; use Customize")
        }
        guard
            registrations.allSatisfy({
                !$0.name.isEmpty && ["user", "team", "global"].contains($0.scope)
            })
        else {
            throw PluginLifecycleError(
                message: "Unrecognized Cursor marketplace JSON registration; use Customize")
        }
        return registrations
    }

    func cursorLimitation(_ request: PluginLifecycleRequest) -> String? {
        if request.action.hasPrefix("marketplace-") {
            return request.scope == "user"
                ? nil
                : "Cursor marketplace changes support personal user registrations only. "
                    + "Use Cursor Dashboard/Customize for team or project sources, then refresh Sukiru."
        }
        return
            "Cursor has no verified non-interactive single-plugin \(request.action) operation. "
            + "Open Cursor Customize or run agent and use the interactive /plugin workflow for \(request.target). "
            + "Choose \(request.scope) scope\(request.scope == "user" ? "" : " in " + request.scopeRoot), "
            + "then refresh Sukiru. Marketplace refresh is not a single-plugin update."
    }
}
