import Foundation

/// The hash-algorithm.md §4.4 confidence gate for `vercel-lock-drift`:
/// reasons a placement's tree can NOT be faithfully compared against a lock
/// `computedHash`. Empty means recompute-eligible.
///
/// Each disqualifier mirrors a known hash-vs-copy divergence (§4.2): symlinks
/// (excluded from the upstream hash, dereferenced into real files by the
/// install copy filter), `node_modules/` (copied but not hashed),
/// `metadata.json` / `__pycache__/` / `__pypackages__/` (hashed but not
/// copied), and non-ASCII relative paths (the upstream ordering is
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

    private func collect(directory: String, relativePrefix: String, into reasons: inout [String]) {
        guard let entries = fileSystem.directoryEntries(atPath: directory) else {
            reasons.append("unreadable directory: \(relativePrefix.isEmpty ? "." : relativePrefix)")
            return
        }
        for name in entries.sorted() {
            let path = HostPathResolver.join(directory, name)
            let relative = relativePrefix + name
            if relative.utf8.contains(where: { $0 >= 0x80 }) {
                reasons.append("non-ASCII path: \(relative)")
            }
            switch fileSystem.entryKind(atPath: path) {
            case .symlink:
                reasons.append("contains symlink: \(relative)")
            case .directory:
                if name == ".git" {
                    continue
                }
                if name == "node_modules" || name == "__pycache__" || name == "__pypackages__" {
                    reasons.append("contains excluded-from-hash directory: \(relative)/")
                } else {
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
}
