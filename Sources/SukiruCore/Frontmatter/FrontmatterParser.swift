import Foundation
import Yams

/// Validated `SKILL.md` frontmatter.
public struct SkillMetadata: Equatable, Sendable {
    /// The required, trimmed, non-empty `name` field.
    public let name: String
    /// The required, trimmed, non-empty `description` field.
    public let description: String
    /// Absolute path of the parsed `SKILL.md` file.
    public let skillFilePath: String
    /// `metadata.internal`, default false; non-bool values are tolerated.
    public let `internal`: Bool
    /// GitHub ledger provenance, present iff `metadata.github-repo` is set.
    public let githubProvenance: GitHubProvenance?

    public init(
        name: String,
        description: String,
        skillFilePath: String,
        internal: Bool,
        githubProvenance: GitHubProvenance?
    ) {
        self.name = name
        self.description = description
        self.skillFilePath = skillFilePath
        self.internal = `internal`
        self.githubProvenance = githubProvenance
    }
}

/// Parses `SKILL.md` frontmatter with byte-exact upstream semantics
/// (upstream `split_frontmatter`):
///
/// - The start delimiter is STRICT: the file's first bytes must be `---\n` or
///   `---\r\n`. There is no BOM tolerance and no leading-blank-line tolerance.
/// - The closing delimiter is the FIRST occurrence of `\n---` in the
///   remainder. It is not line-anchored (`\n---foo` also closes), so a `---`
///   inside a multi-line YAML string truncates the frontmatter early. This is
///   upstream behavior and is reproduced deliberately — do not "fix" it.
/// - `name` and `description` are required: YAML strings (a numeric or bool
///   scalar counts as absent, matching serde_yaml's `as_str`), trimmed,
///   non-empty.
/// - Unknown keys are tolerated; malformed input becomes an `Issue`, never a
///   thrown error or crash.
public struct FrontmatterParser: Sendable {
    private let fileSystem: FileSystemProbe

    public init(fileSystem: FileSystemProbe = DefaultFileSystemProbe()) {
        self.fileSystem = fileSystem
    }

    /// Parses the `SKILL.md` at `path`. Failures are returned as `Issue`s with
    /// kind `skill-md-invalid` (malformed content) or `skill-md-unreadable`
    /// (I/O and encoding failures), mirroring upstream's io/invalid split.
    public func parse(skillFileAt path: String) -> Result<SkillMetadata, Issue> {
        guard let data = fileSystem.fileContents(atPath: path) else {
            return .failure(unreadable(path, "SKILL.md could not be read"))
        }
        // Validate UTF-8 strictly (upstream `read_to_string` fails on invalid
        // bytes), but decode WITHOUT BOM stripping — `String(data:encoding:)`
        // silently eats a leading BOM, which would break the byte-0 delimiter
        // check (no BOM tolerance is upstream behavior).
        guard String(data: data, encoding: .utf8) != nil else {
            return .failure(unreadable(path, "SKILL.md is not valid UTF-8"))
        }
        guard let frontmatter = Self.splitFrontmatter(data) else {
            return .failure(
                invalid(path, "SKILL.md must start with YAML frontmatter delimited by `---`"))
        }
        let root: Node?
        do {
            root = try Yams.compose(yaml: frontmatter)
        } catch {
            return .failure(invalid(path, "invalid YAML in frontmatter: \(error)"))
        }
        guard case .mapping(let mapping) = root else {
            return .failure(invalid(path, "frontmatter must be a YAML mapping"))
        }
        guard let name = Self.requiredString("name", in: mapping) else {
            return .failure(invalid(path, "required frontmatter field `name` is missing"))
        }
        guard let description = Self.requiredString("description", in: mapping) else {
            return .failure(invalid(path, "required frontmatter field `description` is missing"))
        }
        let metadataMapping: Node.Mapping?
        if let metadataNode = mapping["metadata"], case .mapping(let nested) = metadataNode {
            metadataMapping = nested
        } else {
            metadataMapping = nil
        }
        let isInternal = Self.bool(metadataMapping?["internal"]) ?? false
        return .success(
            SkillMetadata(
                name: name,
                description: description,
                skillFilePath: path,
                internal: isInternal,
                githubProvenance: GitHubProvenanceReader.provenance(in: mapping)
            )
        )
    }

    /// Upstream `split_frontmatter` (protocol.rs:93–107): strict start
    /// delimiter, first `\n---` closes. Operates on BYTES like the original —
    /// a Swift `String` would count `\r\n` as one `Character`, and `range(of:)`
    /// is grapheme-aware. Returns the frontmatter text only; the body is not
    /// needed by the read engine.
    static func splitFrontmatter(_ bytes: Data) -> String? {
        let dash: UInt8 = 0x2D
        let lineFeed: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D
        let remainder: Data.SubSequence
        if bytes.starts(with: [dash, dash, dash, lineFeed]) {
            remainder = bytes.dropFirst(4)
        } else if bytes.starts(with: [dash, dash, dash, carriageReturn, lineFeed]) {
            remainder = bytes.dropFirst(5)
        } else {
            return nil
        }
        // The LF pattern alone finds EVERY close: a CRLF close (`\r\n---`)
        // contains `\n---` at index+1, so a separate CRLF arm would be
        // unreachable. The returned slice keeps each line's trailing `\r`,
        // exactly as upstream's byte search does.
        let newlineClose = Self.firstIndex(of: [lineFeed, dash, dash, dash], in: remainder)
        guard let end = newlineClose else {
            return nil
        }
        // The slice is valid UTF-8 (the whole file was validated above).
        return String(bytes: remainder[..<end], encoding: .utf8) ?? ""
    }

    /// First index of a byte pattern in a byte slice, or nil.
    private static func firstIndex(
        of pattern: [UInt8],
        in haystack: Data.SubSequence
    ) -> Data.SubSequence.Index? {
        guard !pattern.isEmpty, haystack.count >= pattern.count else { return nil }
        var index = haystack.startIndex
        let lastStart = haystack.index(haystack.endIndex, offsetBy: 1 - pattern.count)
        while index <= lastStart {
            if haystack[index...].starts(with: pattern) {
                return index
            }
            index = haystack.index(after: index)
        }
        return nil
    }

    /// Upstream `string_field`: the value must be a YAML string scalar
    /// (resolved tag `str`, so `name: 123` counts as absent), trimmed, and
    /// non-empty after trimming.
    static func requiredString(_ key: String, in mapping: Node.Mapping) -> String? {
        guard let node = mapping[key],
            case .scalar = node,
            node.tag.rawValue == Tag.Name.str.rawValue,
            let raw = node.string
        else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A YAML bool scalar (resolved tag `bool`), so `internal: "true"` counts
    /// as absent, matching serde_yaml's `as_bool`.
    static func bool(_ node: Node?) -> Bool? {
        guard let node, node.tag.rawValue == Tag.Name.bool.rawValue else { return nil }
        return node.bool
    }

    /// A scalar's raw string regardless of resolved tag (tolerant accessor for
    /// greenfield fields with no upstream parity constraint).
    static func scalarString(_ node: Node?) -> String? {
        guard let node, case .scalar(let scalar) = node else { return nil }
        let trimmed = scalar.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func invalid(_ path: String, _ message: String) -> Issue {
        Issue(kind: IssueKind.skillMDInvalid, path: path, message: message)
    }

    private func unreadable(_ path: String, _ message: String) -> Issue {
        Issue(kind: IssueKind.skillMDUnreadable, path: path, message: message)
    }
}
