import CryptoKit
import Foundation

/// Recursive, deterministic checksum manifest of a directory tree, for the
/// read-only guarantee: paths + content hashes + symlink
/// targets. A scan must leave the manifest byte-identical.
enum TreeChecksum {
    /// Maps each relative path to `"dir"`, `"file:<sha256>"`,
    /// `"symlink:<raw target>"`, or `"other"`. The root itself is `"."`.
    static func manifest(root: String) throws -> [String: String] {
        var entries: [String: String] = [:]
        try collect(path: root, relative: ".", into: &entries)
        return entries
    }

    private static func collect(
        path: String,
        relative: String,
        into entries: inout [String: String]
    ) throws {
        // attributesOfItem uses lstat semantics for the final component, so a
        // symlink is classified as a symlink (never followed).
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory:
            entries[relative] = "dir"
            let children = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
            for child in children {
                let childRelative = relative == "." ? child : relative + "/" + child
                try collect(path: path + "/" + child, relative: childRelative, into: &entries)
            }
        case .typeSymbolicLink:
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: path)
            entries[relative] = "symlink:\(target)"
        case .typeRegular:
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            entries[relative] = "file:\(digest)"
        default:
            entries[relative] = "other"
        }
    }
}
