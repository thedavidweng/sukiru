import Foundation

@testable import SukiruCore

/// A throwaway directory tree on the real filesystem, removed on deinit.
///
/// Fixture-driven tests build the minimal tree that exercises a behavior and
/// run the real `DefaultFileSystemProbe` over it.
final class TempTree {
    let root: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
        root = base.appendingPathComponent("sukiru-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var path: String { root.path }

    /// The root path fully resolved via realpath(3). macOS temp dirs live
    /// under /var, a symlink to /private/var, and realpath-resolved fields in
    /// scan reports (canonicalPath) use the resolved form — so tests that
    /// prefix-match report paths must start from this.
    var canonicalPath: String {
        DefaultFileSystemProbe().resolvedPath(atPath: path) ?? path
    }

    @discardableResult
    func dir(_ relative: String) throws -> String {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @discardableResult
    func file(_ relative: String, contents: String = "") throws -> String {
        let url = root.appendingPathComponent(relative)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// Creates an executable file at `relative` (POSIX 0755), for PATH-stub
    /// fixtures (capability shims, subprocess-logging shims).
    @discardableResult
    func executable(_ relative: String, contents: String) throws -> String {
        let path = try file(relative, contents: contents)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    /// Creates a symlink at `relative` pointing at the raw target string
    /// (stored verbatim, exactly as `readlink` would report it).
    @discardableResult
    func symlink(_ relative: String, to target: String) throws -> String {
        let url = root.appendingPathComponent(relative)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        return url.path
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
