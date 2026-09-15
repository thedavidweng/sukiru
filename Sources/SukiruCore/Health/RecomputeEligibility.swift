import Foundation

/// The hash-algorithm.md §4.4 confidence gate for `vercel-lock-drift`:
/// reasons a placement's tree can NOT be faithfully compared against a lock
/// `computedHash`. Empty means recompute-eligible.
///
/// Each disqualifier mirrors a known hash-vs-copy divergence (§4.2): symlinks
/// (excluded from the upstream hash, dereferenced into real files by the
/// install copy filter), `node_modules/` (copied but not hashed),
/// `metadata.json` — file OR directory — / `__pycache__/` / `__pypackages__/`
/// (hashed but not copied), and non-ASCII relative paths (the upstream ordering is
/// locale-sensitive for non-ASCII names, §3). `.git/` is excluded by BOTH
/// sides and is harmless, so it is skipped silently. Any unreadable or
/// uninspectable entry also disqualifies — "cannot verify" never becomes a
/// drift accusation.
struct RecomputeEligibility: Sendable {
    private let fileSystem: FileSystemProbe

    init(fileSystem: FileSystemProbe = DefaultFileSystemProbe()) {
        self.fileSystem = fileSystem
    }

    /// All disqualifying reasons for the tree at `root` (empty = eligible).
    func reasons(atPath root: String) -> [String] {
        var reasons: [String] = []
        collect(directory: root, relativePrefix: "", into: &reasons)
        return reasons
    }

    /// How a directory entry participates in the gate.
    private enum DirectoryDisposition {
        /// `.git`: excluded by BOTH sides — harmless, skipped silently.
        case skipSilently
        /// Hashed but never copied (or vice versa): disqualify, no recursion.
        case disqualify(String)
        /// A plain subdirectory: recurse.
        case recurse
    }

    /// A DIRECTORY named `metadata.json` disqualifies like the file case: the
    /// hasher recurses into it (only `.git`/`node_modules` are excluded) while
    /// the install copy filter excludes it by name — the same hash-vs-copy
    /// divergence, so no recursion is needed.
    private static func directoryDisposition(
        name: String, relative: String
    ) -> DirectoryDisposition {
        if name == ".git" {
            return .skipSilently
        }
        if name == "metadata.json" {
            return .disqualify("contains copy-filtered directory: \(relative)/")
        }
        if name == "node_modules" || name == "__pycache__" || name == "__pypackages__" {
            return .disqualify("contains excluded-from-hash directory: \(relative)/")
        }
        return .recurse
    }

    private func collect(directory: String, relativePrefix: String, into reasons: inout [String]) {
        guard let entries = fileSystem.directoryEntries(atPath: directory) else {
            reasons.append("unreadable directory: \(relativePrefix.isEmpty ? "." : relativePrefix)")
            return
        }
        for name in entries.sorted() {
            classifyEntry(
                named: name, inDirectory: directory,
                relativePrefix: relativePrefix, into: &reasons)
        }
    }

    /// Appends every disqualifier one entry contributes, recursing into plain
    /// subdirectories.
    private func classifyEntry(
        named name: String,
        inDirectory directory: String,
        relativePrefix: String,
        into reasons: inout [String]
    ) {
        let path = HostPathResolver.join(directory, name)
        let relative = relativePrefix + name
        if relative.utf8.contains(where: { $0 >= 0x80 }) {
            reasons.append("non-ASCII path: \(relative)")
        }
        switch fileSystem.entryKind(atPath: path) {
        case .symlink:
            reasons.append("contains symlink: \(relative)")
        case .directory:
            switch Self.directoryDisposition(name: name, relative: relative) {
            case .skipSilently:
                return
            case .disqualify(let reason):
                reasons.append(reason)
            case .recurse:
                collect(directory: path, relativePrefix: relative + "/", into: &reasons)
            }
        case .file:
            if name == "metadata.json" {
                reasons.append("contains copy-filtered file: \(relative)")
            }
        case .other, nil:
            reasons.append("uninspectable entry: \(relative)")
        }
    }
}
