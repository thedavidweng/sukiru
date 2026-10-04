import Foundation

/// Keeps link identities and the physical files a native command can write through them.
enum PluginCaptureLinks {
    static func expand(_ paths: [String], environment: SukiruEnvironment) throws -> [String] {
        var roots = Set(paths)
        var visited = Set<String>()
        for path in paths {
            try collectAncestorLinks(path, roots: &roots)
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            try validate(resolved, environment: environment)
            roots.insert(resolved)
            try collect(path, roots: &roots, visited: &visited, environment: environment)
        }
        return roots.sorted()
    }

    /// Capture the link entry only; its directory target is broader than the requested bound.
    private static func collectAncestorLinks(_ path: String, roots: inout Set<String>) throws {
        var parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        while parent != "/" {
            var info = stat()
            if lstat(parent, &info) == 0 {
                let attributes = try FileManager.default.attributesOfItem(atPath: parent)
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    roots.insert(parent)
                }
            } else if errno != ENOENT && errno != ENOTDIR {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
        }
    }

    private static func collect(
        _ path: String, roots: inout Set<String>, visited: inout Set<String>,
        environment: SukiruEnvironment
    ) throws {
        guard visited.insert(path).inserted else { return }
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT || errno == ENOTDIR { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: path)
        switch attributes[.type] as? FileAttributeType {
        case .typeSymbolicLink:
            let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard target != path else {
                throw PluginLifecycleError(message: "Cannot resolve capture link: " + path)
            }
            try validate(target, environment: environment)
            roots.insert(target)
            try collect(target, roots: &roots, visited: &visited, environment: environment)
        case .typeDirectory:
            for name in try manager.contentsOfDirectory(atPath: path) {
                try collect(
                    HostPathResolver.join(path, name), roots: &roots, visited: &visited,
                    environment: environment)
            }
        default: break
        }
    }

    private static func validate(_ path: String, environment: SukiruEnvironment) throws {
        let home = URL(fileURLWithPath: environment.home).resolvingSymlinksInPath().path
        guard path != "/", path != home else {
            throw PluginLifecycleError(message: "Unbounded physical capture root: " + path)
        }
    }
}
