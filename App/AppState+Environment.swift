import Foundation
import SukiruCore

extension AppState {
    /// Builds a scan environment identical to the CLI wiring except
    /// that the runtime project-roots list replaces `SUKIRU_ROOTS`.
    /// Explicit roots are encoded back into `SUKIRU_ROOTS` so the engine's
    /// root precedence (explicit `--root` never merges) is untouched — the app
    /// always scans with default precedence over ITS root list. Also used by
    /// the batch executors (CLIExecutor, Rollback) so app-initiated
    /// mutations run against exactly the scanned environment.
    static func makeEnvironment(roots: [String]) -> SukiruEnvironment {
        var vars = ProcessInfo.processInfo.environment
        if roots.isEmpty {
            vars.removeValue(forKey: SukiruEnvironment.sukiruRootsKey)
        } else {
            vars[SukiruEnvironment.sukiruRootsKey] = roots.joined(separator: ":")
        }
        return SukiruEnvironment(reader: DictionaryEnvironmentReader(vars))
    }
}
