import Foundation

extension PluginLifecyclePlanner {
    func openCodeLimitation(_ request: PluginLifecycleRequest, version: String) -> String? {
        if version == "v1.18.34" || version == "1.18.34" {
            return ["install", "replace"].contains(request.action)
                ? nil
                : "OpenCode v1 supports package install and force replacement only; native removal is unavailable."
        }
        guard version == "v2.0.22" || version == "2.0.22" else {
            return "OpenCode \(version) has no verified lifecycle contract; use the host."
        }
        if ["list", "check", "update"].contains(request.action) {
            if request.scope == "local" {
                return "OpenCode v2 runtime operations use user or project scope."
            }
            if ["/", ".", "file:"].contains(where: { request.target.hasPrefix($0) }) {
                return
                    "OpenCode package checks/updates skip local files; use local compatibility inspection."
            }
            if request.action == "list" && request.target != "*" {
                return
                    "OpenCode v2 list has no individual target; use * to list the selected runtime."
            }
            return nil
        }
        if request.scope != "user" {
            return "OpenCode v2 add/remove manage global package configuration only."
        }
        if !["install", "remove"].contains(request.action) {
            return "OpenCode has no native \(request.action) interface."
        }
        let localTarget = ["/", ".", "file:"].contains { request.target.hasPrefix($0) }
        if localTarget {
            return
                "OpenCode local discovered files have no native package deletion/install operation; "
                + "package removal does not delete local files."
        }
        return nil
    }

    func openCodeV1Arguments(_ request: PluginLifecycleRequest) -> [String] {
        var args = ["opencode", "plugin", request.target]
        if request.scope == "user" { args.append("--global") }
        if request.action == "replace" { args.append("--force") }
        return args
    }

}
