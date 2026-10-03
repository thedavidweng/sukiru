import CryptoKit
import Foundation

/// Full-fidelity recursive directory copies and deterministic digests for
/// snapshot payloads.
///
/// Unlike `ContentHasher` (upstream computedHash parity), a payload copy is
/// COMPLETE: dotfiles, `.git`, `node_modules`, and symlinks are all carried.
/// Symlinks are recreated with their verbatim target strings and never
/// followed, so dangling links and cycles are preserved as data.
enum PayloadTree {
    /// Recursively copies the directory at `source` to `destination`
    /// (created, with intermediate directories). Throws on any unreadable
    /// entry — capture treats that as a total failure.
    static func copyDirectory(from source: String, to destination: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: destination, withIntermediateDirectories: true)
        let children = try fileManager.contentsOfDirectory(atPath: source).sorted()
        for child in children {
            let childSource = HostPathResolver.join(source, child)
            let childDestination = HostPathResolver.join(destination, child)
            // attributesOfItem uses lstat semantics for the final component:
            // symlinks report as links and are never followed.
            let attributes = try fileManager.attributesOfItem(atPath: childSource)
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory:
                try copyDirectory(from: childSource, to: childDestination)
            case .typeSymbolicLink:
                let target = try fileManager.destinationOfSymbolicLink(atPath: childSource)
                try fileManager.createSymbolicLink(
                    atPath: childDestination, withDestinationPath: target)
            case .typeRegular:
                try fileManager.copyItem(atPath: childSource, toPath: childDestination)
            default:
                // FIFOs/sockets/devices cannot be meaningfully copied; they
                // are not valid skill payload content either.
                throw SnapshotError.captureFailed("unsupported file type at \(childSource)")
            }
        }
    }

    /// A deterministic digest of the full recursive tree: SHA-256 over the
    /// sorted-entry lines `<relativePath>\t<kind>[\t<detail>]`, where detail
    /// is the file's SHA-256 hex or the symlink's verbatim target.
    static func digest(root: String) throws -> String {
        let lines = try manifestLines(root: root)
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The digest's underlying lines, in deterministic order (children are
    /// visited name-sorted). Entry names containing a tab or newline would
    /// collide in this encoding; such names are pathological and rejected by
    /// the installers Sukiru interoperates with.
    static func manifestLines(root: String) throws -> [String] {
        var lines: [String] = []
        try collect(path: root, relative: ".", into: &lines)
        return lines
    }

    private static func collect(path: String, relative: String, into lines: inout [String]) throws {
        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(atPath: path)
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory:
            lines.append("\(relative)\tdir")
            let children = try fileManager.contentsOfDirectory(atPath: path).sorted()
            for child in children {
                let childRelative = relative == "." ? child : relative + "/" + child
                let childPath = HostPathResolver.join(path, child)
                try collect(path: childPath, relative: childRelative, into: &lines)
            }
        case .typeSymbolicLink:
            let target = try fileManager.destinationOfSymbolicLink(atPath: path)
            lines.append("\(relative)\tsymlink\t\(target)")
        case .typeRegular:
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            lines.append("\(relative)\tfile\t\(hex)")
        default:
            lines.append("\(relative)\tother")
        }
    }
}
