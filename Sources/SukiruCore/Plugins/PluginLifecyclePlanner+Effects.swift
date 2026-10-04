import Foundation

extension PluginLifecyclePlanner {
    func helpArgumentCount(_ request: PluginLifecycleRequest, version: String) -> Int {
        if request.host == .opencode && ["1.18.34", "v1.18.34"].contains(version) { return 1 }
        return request.action.hasPrefix("marketplace-") ? 3 : 2
    }

    func effectsFlags(_ request: PluginLifecycleRequest, version: String) -> [DangerFlag] {
        if request.host == .opencode && ["1.18.34", "v1.18.34"].contains(version) {
            return [.pluginRuntimeEffects]
        }
        if request.host == .opencode && ["list", "check", "update"].contains(request.action) {
            return [.pluginRuntimeEffects]
        }
        if request.host == .codex && request.target.hasSuffix("@openai-curated-remote") {
            return [.backendStateChange]
        }
        return []
    }

    func effectsWarning(_ request: PluginLifecycleRequest, version: String) -> String {
        guard !effectsFlags(request, version: version).isEmpty else { return "" }
        if request.host == .codex {
            return " This operation changes remote backend installation state. "
                + "File rollback restores captured local files only; it does not reverse backend installation changes. "
                + "Explicit consent to these effects is required before execution."
        }
        let target =
            request.target == "*" ? "all package plugins in the selected runtime" : request.target
        return
            " This official operation may start/connect to a host and initialize plugin code for \(target). "
            + "Plugin code may change files outside captured roots or external state; "
            + "file rollback cannot undo those effects. "
            + (request.action == "replace"
                ? "Force replacement replaces the configured version. " : "")
            + (["check", "update"].contains(request.action)
                ? "The host skips exact version/full commit locks and local-file updates; no locks are changed. "
                : "")
            + "Explicit consent to these effects is required before execution."
    }
}
