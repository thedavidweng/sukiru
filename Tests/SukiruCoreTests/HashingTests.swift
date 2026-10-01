import Foundation
import Testing

@testable import SukiruCore

/// `ContentHasher` behavior: ICU ordering parity with Node `localeCompare`,
/// the project-scope exclusion set, failure-as-data, the hash-family
/// discriminator, and the upstream parity canary fixture.
/// Digest golden vectors live in `HashingVectorTests`.
///
/// Load-bearing rules: files sort with ICU collation via
/// `String.compare(_:options:[], range:nil, locale: en_US)` — NEVER
/// `localizedStandardCompare`; directories `.git`/`node_modules` are excluded
/// at every depth while `metadata.json` and dotfiles are included; symlinks
/// hash as the literal `symlink:"<target>"` bytes and are never traversed.
@Suite("Content hasher")
struct ContentHasherTests {
    private let hasher = ContentHasher()

    private func hash(of result: Result<String, ScanIssue>) -> String? {
        if case .success(let hex) = result { return hex }
        return nil
    }

    private func files(of result: Result<[SkillFile], ScanIssue>) -> [SkillFile]? {
        if case .success(let files) = result { return files }
        return nil
    }

    private func failure(of result: Result<String, ScanIssue>) -> ScanIssue? {
        if case .failure(let issue) = result { return issue }
        return nil
    }

    // MARK: - ICU ordering parity with Node localeCompare

    @Test("Tricky filename ordering matches Node localeCompare")
    func orderingMatchesNodeLocaleCompare() throws {
        let tree = try TempTree()
        let skill = "skills/order"
        let names =
            """
            a.md
            B.md
            SKILL.md
            scripts/run.sh
            _x.md
            Z.md
            zz.md
            1.md
            é.md
            e.md
            """
            .split(separator: "\n").map(String.init)
        for name in names {
            try tree.file("\(skill)/\(name)", contents: "x\n")
        }

        let collected = try #require(files(of: hasher.skillFiles(atPath: "\(tree.path)/\(skill)")))
        // Node: [...].sort((a, b) => a.localeCompare(b)).
        let expected =
            """
            _x.md
            1.md
            a.md
            B.md
            e.md
            é.md
            scripts/run.sh
            SKILL.md
            Z.md
            zz.md
            """
            .split(separator: "\n").map(String.init)
        #expect(collected.map(\.relativePath) == expected)
    }

    @Test("SKILL.md sorts after scripts/ and agents/, numerics sort by character")
    func trickyPairOrdering() throws {
        let tree = try TempTree()
        let skill = "skills/pairs"
        let names =
            """
            SKILL.md
            scripts/run.sh
            agents/helper.md
            10-x.md
            2-y.md
            """
            .split(separator: "\n").map(String.init)
        for name in names {
            try tree.file("\(skill)/\(name)", contents: "x\n")
        }

        let collected = try #require(files(of: hasher.skillFiles(atPath: "\(tree.path)/\(skill)")))
        // Node localeCompare: [10-x.md, 2-y.md, agents/helper.md, scripts/run.sh, SKILL.md]
        let expected =
            """
            10-x.md
            2-y.md
            agents/helper.md
            scripts/run.sh
            SKILL.md
            """
            .split(separator: "\n").map(String.init)
        #expect(collected.map(\.relativePath) == expected)
    }

    // MARK: - Exclusion set (project scope)

    @Test("Project exclusions: .git and node_modules dirs only, at every depth")
    func projectScopeExclusions() throws {
        let base = try TempTree()
        let variant = try TempTree()
        for tree in [base, variant] {
            try tree.file("skill/SKILL.md", contents: "---\nname: x\ndescription: d.\n---\n")
            try tree.file("skill/notes.md", contents: "shared\n")
        }
        // Excluded content differs between the two trees; the hashes must not.
        try base.file("skill/.git/cfg", contents: "git one\n")
        try base.file("skill/node_modules/pkg/index.js", contents: "module one\n")
        try base.file("skill/nested/node_modules/deep.js", contents: "deep one\n")
        try variant.file("skill/.git/cfg", contents: "git two — different\n")
        try variant.file("skill/node_modules/pkg/index.js", contents: "module two\n")
        try variant.file("skill/nested/node_modules/deep.js", contents: "deep two\n")

        let baseHash = hash(of: hasher.computedHash(ofSkillAtPath: "\(base.path)/skill"))
        let variantHash = hash(of: hasher.computedHash(ofSkillAtPath: "\(variant.path)/skill"))
        #expect(baseHash != nil)
        #expect(baseHash == variantHash)
    }

    @Test("metadata.json and dotfiles are INCLUDED in the project-scope hash")
    func metadataAndDotfilesIncluded() throws {
        let withMeta = try TempTree()
        let withoutMeta = try TempTree()
        for tree in [withMeta, withoutMeta] {
            try tree.file("skill/SKILL.md", contents: "---\nname: x\ndescription: d.\n---\n")
        }
        try withMeta.file("skill/metadata.json", contents: "{}\n")

        let hashWith = hash(of: hasher.computedHash(ofSkillAtPath: "\(withMeta.path)/skill"))
        let hashWithout = hash(of: hasher.computedHash(ofSkillAtPath: "\(withoutMeta.path)/skill"))
        #expect(hashWith != nil && hashWithout != nil)
        #expect(hashWith != hashWithout)

        // A stray dotfile (e.g. Finder's .DS_Store) likewise changes the hash.
        try withoutMeta.file("skill/.DS_Store", contents: "finder noise")
        let hashWithDotfile = hash(
            of: hasher.computedHash(ofSkillAtPath: "\(withoutMeta.path)/skill"))
        #expect(hashWithDotfile != hashWithout)
    }

    // MARK: - Failure is data, never a crash

    @Test("Unreadable subdirectory yields an issue, not a crash")
    func unreadableSubdirectoryYieldsIssue() throws {
        let tree = try TempTree()
        try tree.file("skills/s/SKILL.md", contents: "---\nname: s\ndescription: d.\n---\n")
        let sealed = try tree.dir("skills/s/sealed")
        try tree.file("skills/s/sealed/secret.md", contents: "hidden\n")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: sealed)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: sealed)
        }

        let result = hasher.computedHash(ofSkillAtPath: "\(tree.path)/skills/s")
        let issue = try #require(failure(of: result), "expected an unreadable issue")
        #expect(issue.kind == IssueKind.contentHashUnreadable)
        #expect(issue.path.contains("sealed"))
    }

    @Test("Missing skill root yields an issue, not a crash")
    func missingRootYieldsIssue() throws {
        let tree = try TempTree()
        let result = hasher.computedHash(ofSkillAtPath: "\(tree.path)/nope")
        let issue = try #require(failure(of: result), "expected a missing-root issue")
        #expect(issue.kind == IssueKind.contentHashUnreadable)
    }

    // MARK: - Hash family discriminator

    @Test("40-hex values are git tree SHAs; 64-hex are sha256 folder hashes")
    func hashFamilyDiscriminator() {
        #expect(ContentHasher.isGitTreeSHA("cb6e53477eaf04e6daeca22feacb85f9ce20d40c"))
        #expect(ContentHasher.isGitTreeSHA("CB6E53477EAF04E6DAECA22FEACB85F9CE20D40C"))
        #expect(
            !ContentHasher.isGitTreeSHA(
                "4db3d555c1b5224c98042b82b7b2bcf9479f77898dcd8abd950a45d0f2371281"))
        #expect(
            ContentHasher.isSHA256FolderHash(
                "4db3d555c1b5224c98042b82b7b2bcf9479f77898dcd8abd950a45d0f2371281"))
        #expect(!ContentHasher.isSHA256FolderHash("cb6e53477eaf04e6daeca22feacb85f9ce20d40c"))
        #expect(!ContentHasher.isGitTreeSHA(""))
        #expect(!ContentHasher.isSHA256FolderHash("xyz"))
    }

    @Test("Non-ASCII 'hex' digits never classify — upstream's discriminator is ASCII-only")
    func hashFamilyDiscriminatorRejectsNonASCII() {
        // Character.isHexDigit is Unicode-aware: U+FF11 FULLWIDTH DIGIT ONE
        // satisfies it. Upstream's discriminator is /^[0-9a-f]{40|64}$/i —
        // ASCII only — so a fullwidth string must NOT classify.
        #expect(Character("\u{FF11}").isHexDigit)
        let fullwidth40 = String(repeating: "\u{FF11}", count: 40)
        let fullwidth64 = String(repeating: "\u{FF11}", count: 64)
        #expect(!ContentHasher.isGitTreeSHA(fullwidth40))
        #expect(!ContentHasher.isSHA256FolderHash(fullwidth64))
        // Mixed ASCII + one non-ASCII digit is also out.
        let almostASCII = String(repeating: "a", count: 39) + "\u{FF11}"
        #expect(!ContentHasher.isGitTreeSHA(almostASCII))
    }

    @Test("An uninspectable directory entry yields an issue, never a silent drop")
    func uninspectableEntryYieldsIssue() {
        // entryKind == nil covers a symlink whose target cannot be read
        // (readlink failure): the hasher must report it, not skip the entry.
        let stub = StubFileSystem(
            existing: ["/s"], directories: ["/s"], entries: ["/s": ["mystery"]])
        let result = ContentHasher(fileSystem: stub).computedHash(ofSkillAtPath: "/s")
        let issue = failure(of: result)
        #expect(issue?.kind == IssueKind.contentHashUnreadable)
        #expect(issue?.path == "/s/mystery")
    }

    // MARK: - Upstream parity canary

    @Test("Canary fixture: recomputed hash equals the real CLI's lock value")
    func canaryFixtureMatchesUpstreamLock() throws {
        let fixture = FixturePaths.tree("hash-parity")
        let lockPath = "\(fixture)/proj/skills-lock.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: lockPath))
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let skills = try #require(root["skills"] as? [String: Any])
        let entry = try #require(skills["hashprobe"] as? [String: Any])
        let locked = try #require(entry["computedHash"] as? String)

        let placement = "\(fixture)/proj/.agents/skills/hashprobe"
        let recomputed = hash(of: hasher.computedHash(ofSkillAtPath: placement))
        #expect(recomputed != nil, "canary placement failed to hash")
        #expect(
            recomputed == locked,
            "recomputed \(recomputed ?? "nil") != lock \(locked) (skills@1.5.26)"
        )
    }
}
