import Foundation

extension PluginLifecyclePlanner {
    func openCodeLimitation(
        _ request: PluginLifecycleRequest, version: String, inventory: PluginInventory
    ) -> String? {
        switch PluginHostContract(host: .opencode, version: version) {
        case .openCodeV1: openCodeV1Limitation(request)
        case .openCodeV2: openCodeV2Limitation(request, inventory: inventory)
        default:
            PluginHostContract.unverified(host: .opencode, version: version, name: "OpenCode")
        }
    }

    private func openCodeV1Limitation(_ request: PluginLifecycleRequest) -> String? {
        guard ["install", "replace"].contains(request.action) else {
            return
                "OpenCode v1 supports package install and force replacement only; native removal is unavailable."
        }
        return isLocalTarget(request)
            ? "OpenCode v1 installs npm package specs; configure local plugin files directly in the host."
            : nil
    }

    private func openCodeV2Limitation(
        _ request: PluginLifecycleRequest, inventory: PluginInventory
    ) -> String? {
        if discoveredOnly(request, inventory: inventory) {
            return
                "\(request.target) is an auto-discovered local file, not a configured package. "
                + "OpenCode has no native deletion for local files; "
                + "use Disable Local Loading or remove the file in Finder."
        }
        if ["list", "check", "update"].contains(request.action) {
            return openCodeRuntimeLimitation(request)
        }
        if request.scope != "user" {
            return "OpenCode v2 add/remove manage global package configuration only."
        }
        if !["install", "remove"].contains(request.action) {
            return "OpenCode has no native \(request.action) interface."
        }
        if isLocalTarget(request) {
            return
                "OpenCode local discovered files have no native package deletion/install operation; "
                + "package removal does not delete local files."
        }
        return nil
    }

    private func openCodeRuntimeLimitation(_ request: PluginLifecycleRequest) -> String? {
        if request.scope == "local" {
            return "OpenCode v2 runtime operations use user or project scope."
        }
        if isLocalTarget(request) {
            return
                "OpenCode package checks/updates skip local files; use local compatibility inspection."
        }
        if request.action == "list" && request.target != "*" {
            return
                "OpenCode v2 list has no individual target; use * to list the selected runtime."
        }
        return nil
    }

    private func isLocalTarget(_ request: PluginLifecycleRequest) -> Bool {
        ["/", ".", "file:"].contains { request.target.hasPrefix($0) }
    }

    /// A target naming only auto-discovered files must not become a package
    /// configuration removal of the same name.
    private func discoveredOnly(
        _ request: PluginLifecycleRequest, inventory: PluginInventory
    ) -> Bool {
        let matches = inventory.installations.filter {
            $0.host == .opencode && ($0.identifier == request.target || $0.path == request.target)
        }
        return !matches.isEmpty && matches.allSatisfy { $0.installationStatus == "discovered" }
    }

    /// The npm package name of a spec such as `@scope/name@1.2.0` or `name@^2`.
    static func packageName(_ spec: String) -> String {
        let searchStart = spec.hasPrefix("@") ? spec.index(after: spec.startIndex) : spec.startIndex
        guard let separator = spec[searchStart...].firstIndex(of: "@") else { return spec }
        return String(spec[..<separator])
    }

    func openCodeV1Arguments(_ request: PluginLifecycleRequest) -> [String] {
        var args = ["opencode", "plugin", request.target]
        if request.scope == "user" { args.append("--global") }
        if request.action == "replace" { args.append("--force") }
        return args
    }

}
