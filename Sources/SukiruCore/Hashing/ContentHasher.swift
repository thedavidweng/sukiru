import CryptoKit
import Foundation

/// One hashed entry of a skill directory (port-reference §6 `SkillFile`):
/// the `/`-joined path relative to the skill root plus the exact bytes that
/// participate in the digest. For a symlink the bytes are the literal string
/// `symlink:"<target>"` (Rust-Debug quoting), never the target's content.
public struct SkillFile: Equatable, Sendable {
    public let relativePath: String
    public let bytes: Data

    public init(relativePath: String, bytes: Data) {
        self.relativePath = relativePath
        self.bytes = bytes
    }
}

/// Byte-exact reproduction of the upstream `skills` CLI's project-lock
/// `computedHash` (architecture §4.1, research/hash-algorithm.md §1–§3,
/// port-reference §6 `collect_project_skill_files` / `hash_files` and traps
/// #6–#9).
///
/// The algorithm, normatively:
/// 1. Recursively collect regular files under the skill root. Directories
///    named `.git` or `node_modules` are skipped AT EVERY DEPTH (the project
///    exclusion set — `metadata.json`, `__pycache__`, dotfiles etc. ARE
///    included, unlike the install-time copy filter).
/// 2. A symlink contributes a `SkillFile` whose bytes are the literal
///    `symlink:"<target>"` (Rust `{:?}` quoting of the raw, unresolved target
///    string) and is NEVER descended into. Upstream's `collectFiles` EXCLUDES
///    symlinks entirely (Node `Dirent.isFile()` is false for links), so a
///    symlink-bearing tree can never match a real CLI lock — that divergence
///    is documented upstream behavior (hash-algorithm.md §4.2), and the
///    archive's deterministic convention is kept so symlinked skills still
///    fingerprint stably for Sukiru's own duplicate/divergence detection.
/// 3. Relative paths join components with `/`; a literal `\` inside a file
///    NAME becomes `/` (upstream's `.split("\\").join("/")` quirk, reproduced).
/// 4. Entries sort by ICU collation —
///    `String.compare(_:options:[], range:nil, locale: en_US)`, verified
///    against Node's `localeCompare` (hash-algorithm.md §3). NEVER
///    `localizedStandardCompare` (it diverges on numeric names). A bytewise
///    tiebreak keeps collation-equal-but-distinct paths deterministic.
/// 5. SHA-256 over `utf8(relativePath) + fileBytes` per entry, concatenated
///    with NO separators, no length prefixes, no trailing delimiter.
///
/// The global lock's `skillFolderHash` is a git tree SHA — passthrough
/// display only, NEVER recomputed here (hash-algorithm.md §6).
public struct ContentHasher: Sendable {
    /// The collation locale whose ordering matches Node's default
    /// `localeCompare` on the verified filename sets (hash-algorithm.md §3).
    private static let collationLocale = Locale(identifier: "en_US")

    private let fileSystem: FileSystemProbe

    public init(fileSystem: FileSystemProbe = DefaultFileSystemProbe()) {
        self.fileSystem = fileSystem
    }

    // MARK: - Hash family discriminator (hash-algorithm.md §0)

    /// Upstream's discriminator: a 40-hex value is a git tree SHA (global
    /// `skillFolderHash`, `metadata.github-tree-sha`) — provenance data only,
    /// never locally recomputable.
    public static func isGitTreeSHA(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy(\.isHexDigit)
    }

    /// A 64-hex value is a sha256 folder hash (project `computedHash`) — the
    /// only locally recomputable ledger hash.
    public static func isSHA256FolderHash(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    // MARK: - Collection

    /// The sorted hash input set for the skill directory at `path`. The root
    /// itself may be a symlink (it is followed, matching upstream hashing a
    /// resolved directory); entries INSIDE use lstat semantics. Any read
    /// failure becomes an `Issue`, never a thrown error.
    public func skillFiles(atPath path: String) -> Result<[SkillFile], Issue> {
        guard fileSystem.isDirectory(atPath: path) else {
            return .failure(unreadable(path, "skill directory does not exist or is not readable"))
        }
        var files: [SkillFile] = []
        if let issue = collect(into: &files, directory: path, relativePrefix: "") {
            return .failure(issue)
        }
        files.sort(by: Self.isOrderedBefore)
        return .success(files)
    }

    /// The upstream `computedHash`: lowercase hex SHA-256 over the sorted
    /// entries' `utf8(relativePath) + bytes`, no separators.
    public func computedHash(ofSkillAtPath path: String) -> Result<String, Issue> {
        skillFiles(atPath: path).map { files in
            var hasher = SHA256()
            for file in files {
                hasher.update(data: Data(file.relativePath.utf8))
                hasher.update(data: file.bytes)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Recursive walk. Returns an `Issue` on the first unreadable entry, nil
    /// on success (upstream fails the whole hash on IO errors; the scan layer
    /// records the issue and continues).
    private func collect(
        into files: inout [SkillFile], directory: String, relativePrefix: String
    ) -> Issue? {
        guard let entries = fileSystem.directoryEntries(atPath: directory) else {
            return unreadable(directory, "directory could not be read")
        }
        for name in entries {
            let path = HostPathResolver.join(directory, name)
            let relativePath = Self.normalizeRelativePath(relativePrefix + name)
            guard let kind = fileSystem.entryKind(atPath: path) else {
                return unreadable(path, "directory entry could not be inspected")
            }
            switch kind {
            case .symlink(let target):
                files.append(
                    SkillFile(
                        relativePath: relativePath,
                        bytes: Data(Self.rustDebugQuotedSymlink(target).utf8)
                    ))
            case .directory:
                // Project-scope exclusion set: `.git` and `node_modules` only.
                guard name != ".git", name != "node_modules" else { continue }
                if let issue = collect(
                    into: &files, directory: path, relativePrefix: relativePath + "/"
                ) {
                    return issue
                }
            case .file:
                guard let bytes = fileSystem.fileContents(atPath: path) else {
                    return unreadable(path, "file could not be read")
                }
                files.append(SkillFile(relativePath: relativePath, bytes: bytes))
            case .other:
                // FIFOs, sockets, devices: excluded, like upstream.
                continue
            }
        }
        return nil
    }

    // MARK: - Ordering and quoting

    /// ICU collation order with a deterministic bytewise tiebreak. Node's
    /// sort is stable (tie = readdir order, platform-dependent); Sukiru
    /// requires identical output on every machine, so collation-equal
    /// distinct paths fall back to literal order.
    private static func isOrderedBefore(_ left: SkillFile, _ right: SkillFile) -> Bool {
        switch left.relativePath.compare(
            right.relativePath, options: [], range: nil, locale: collationLocale
        ) {
        case .orderedAscending:
            return true
        case .orderedDescending:
            return false
        case .orderedSame:
            return left.relativePath.compare(right.relativePath, options: .literal)
                == .orderedAscending
        }
    }

    /// `/`-joined relative path with upstream's `\` → `/` name normalization
    /// (Node's `relative(...).split("\\").join("/")` turns a backslash inside
    /// a file NAME into a separator in the hash key).
    private static func normalizeRelativePath(_ path: String) -> String {
        String(path.map { $0 == "\\" ? "/" : $0 })
    }

    /// The bytes a symlink contributes: `symlink:"<target>"` where the target
    /// is quoted exactly like Rust's `{:?}` on a string — wrapped in double
    /// quotes, with `\t` `\r` `\n` `\` `"` `'` backslash-escaped and other
    /// control characters rendered as `\u{<lowercase hex>}` (port-reference
    /// trap #7). Printable non-ASCII passes through unescaped.
    static func rustDebugQuotedSymlink(_ target: String) -> String {
        var quoted = "\""
        for scalar in target.unicodeScalars {
            switch scalar {
            case "\t":
                quoted += "\\t"
            case "\r":
                quoted += "\\r"
            case "\n":
                quoted += "\\n"
            case "\\":
                quoted += "\\\\"
            case "\"":
                quoted += "\\\""
            case "'":
                quoted += "\\'"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    quoted += "\\u{\(String(scalar.value, radix: 16))}"
                } else {
                    quoted.unicodeScalars.append(scalar)
                }
            }
        }
        quoted += "\""
        return "symlink:" + quoted
    }

    private func unreadable(_ path: String, _ message: String) -> Issue {
        Issue(kind: IssueKind.contentHashUnreadable, path: path, message: message)
    }
}
