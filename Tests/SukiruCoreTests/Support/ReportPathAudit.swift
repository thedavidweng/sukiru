import Foundation

/// Hermeticity audit support (VAL-SCAN-004): collects every absolute path
/// string appearing anywhere in a parsed JSON tree and checks each one lies
/// under an allowed root.
enum ReportPathAudit {
    /// Every string in the JSON value tree that looks like an absolute path.
    static func absolutePaths(in value: Any) -> [String] {
        switch value {
        case let object as [String: Any]:
            return object.values.flatMap { absolutePaths(in: $0) }
        case let array as [Any]:
            return array.flatMap { absolutePaths(in: $0) }
        case let string as String where string.hasPrefix("/"):
            return [string]
        default:
            return []
        }
    }

    /// The subset of `paths` lying outside every allowed root (path-component
    /// aware: `/a/b` matches root `/a` but not root `/a/b` vs `/a/bc`).
    static func pathsOutside(_ paths: [String], allowedRoots: [String]) -> [String] {
        paths.filter { path in
            !allowedRoots.contains { root in
                path == root || path.hasPrefix(root + "/")
            }
        }
    }
}
