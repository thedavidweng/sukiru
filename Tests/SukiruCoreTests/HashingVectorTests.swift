import Foundation
import Testing

@testable import SukiruCore

/// `ContentHasher` golden digest vectors.
///
/// Every expected digest below was produced independently of the Swift
/// implementation: the `sortcase` vector is the REAL `skills@1.5.26` CLI's
/// own lock value (research/hash-algorithm.md §8, fixture preserved from the
/// research sandbox); the symlink vectors come from a Node reference
/// transcription of the published CLI's `computeSkillFolderHash` extended
/// with the archive's `symlink:"<target>"` convention (port-reference trap
/// #7). They pin byte-exactness of the digest construction: SHA-256 over
/// `utf8(relativePath) + bytes`, sorted by ICU collation, no separators.
@Suite("Content hasher golden vectors")
struct ContentHasherVectorTests {
    private let hasher = ContentHasher()

    private func hash(of result: Result<String, ScanIssue>) -> String? {
        if case .success(let hex) = result { return hex }
        return nil
    }

    private func files(of result: Result<[SkillFile], ScanIssue>) -> [SkillFile]? {
        if case .success(let files) = result { return files }
        return nil
    }

    @Test("Golden sortcase vector matches the real CLI's computedHash")
    func goldenSortcaseVector() throws {
        let tree = try TempTree()
        let skill = "skills/sortcase"
        try tree.file(
            "\(skill)/SKILL.md",
            contents: "---\nname: sortcase\n"
                + "description: A fixture skill used to prove file ordering in the hash.\n"
                + "---\nbody\n"
        )
        try tree.file("\(skill)/scripts/run.sh", contents: "aaa\n")
        try tree.file("\(skill)/_notes.md", contents: "bbb\n")
        try tree.file("\(skill)/Zebra.md", contents: "ccc\n")
        try tree.file("\(skill)/apple.md", contents: "ddd\n")

        let result = hasher.computedHash(ofSkillAtPath: "\(tree.path)/\(skill)")
        #expect(
            hash(of: result)
                == "4db3d555c1b5224c98042b82b7b2bcf9479f77898dcd8abd950a45d0f2371281"
        )

        // The same tree pins the ICU file order (Node localeCompare output).
        let collected = try #require(files(of: hasher.skillFiles(atPath: "\(tree.path)/\(skill)")))
        let expectedOrder =
            "_notes.md\napple.md\nscripts/run.sh\nSKILL.md\nZebra.md"
            .split(separator: "\n").map(String.init)
        #expect(collected.map(\.relativePath) == expectedOrder)
    }

    @Test("Symlinks hash as symlink:\"<target>\" and are never traversed")
    func symlinksHashAsDebugQuotedTarget() throws {
        let tree = try TempTree()
        let skill = "skills/linky"
        try tree.file(
            "\(skill)/SKILL.md",
            contents: "---\nname: linky\ndescription: Symlink hashing.\n---\nbody\n"
        )
        try tree.file("\(skill)/target/one.md", contents: "payload\n")
        try tree.file("\(skill)/target/sub/two.md", contents: "nested\n")
        try tree.symlink("\(skill)/ref.txt", to: "target/one.md")
        try tree.symlink("\(skill)/dirlink", to: "target")

        let result = hasher.computedHash(ofSkillAtPath: "\(tree.path)/\(skill)")
        // Independent Node reference (Rust-Debug quoting, symlinked dirs not
        // descended).
        #expect(
            hash(of: result)
                == "ed67f458e692462d6a69bfdcae895e2a8ae968e6e4a5091538504f55ff3efcb5"
        )

        let collected = try #require(files(of: hasher.skillFiles(atPath: "\(tree.path)/\(skill)")))
        let byPath = Dictionary(
            uniqueKeysWithValues: collected.map { ($0.relativePath, $0.bytes) })
        #expect(byPath["ref.txt"] == Data(#"symlink:"target/one.md""#.utf8))
        #expect(byPath["dirlink"] == Data(#"symlink:"target""#.utf8))
        // The symlinked directory contributes no descendant entries.
        #expect(!collected.contains { $0.relativePath.hasPrefix("dirlink/") })
    }

    @Test("Symlink target quoting follows Rust Debug escaping")
    func symlinkTargetEscapingMatchesRustDebug() throws {
        let tree = try TempTree()
        let skill = "skills/esc"
        try tree.file(
            "\(skill)/SKILL.md",
            contents: "---\nname: esc\ndescription: Escape quoting.\n---\n"
        )
        // Double quote, backslash, single quote in one name. Rust Debug
        // escapes all three; the backslash in the FILE's own relative path
        // becomes '/' (upstream's `\` → `/` normalization applies to names).
        let weird = "we\"ird\\it's.md"
        try tree.file("\(skill)/\(weird)", contents: "x\n")
        try tree.symlink("\(skill)/esc.txt", to: weird)

        let result = hasher.computedHash(ofSkillAtPath: "\(tree.path)/\(skill)")
        #expect(
            hash(of: result)
                == "05111efd34742b78f8550c863449a98f8727a9c5a6c1c0485959fa8b865e05cc"
        )

        let collected = try #require(files(of: hasher.skillFiles(atPath: "\(tree.path)/\(skill)")))
        let byPath = Dictionary(
            uniqueKeysWithValues: collected.map { ($0.relativePath, $0.bytes) })
        #expect(byPath["esc.txt"] == Data(#"symlink:"we\"ird\\it\'s.md""#.utf8))
        #expect(byPath[#"we"ird/it's.md"#] == Data("x\n".utf8))
    }

    @Test("Empty skill directory hashes as SHA-256 of the empty input")
    func emptyDirectory() throws {
        let tree = try TempTree()
        try tree.dir("skills/empty")
        let result = hasher.computedHash(ofSkillAtPath: "\(tree.path)/skills/empty")
        #expect(
            hash(of: result)
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    @Test("Empty files contribute their relative path only")
    func emptyFileContributesPathOnly() throws {
        let tree = try TempTree()
        try tree.file("skills/p/only.txt", contents: "")
        // sha256("only.txt") — the path bytes with zero content bytes.
        let result = hasher.computedHash(ofSkillAtPath: "\(tree.path)/skills/p")
        #expect(
            hash(of: result)
                == "08c87c8e2482e76b2bd1f7c30898a8cc7a7b66b67cc8e331b6e0a49ca8c64207"
        )
    }
}
