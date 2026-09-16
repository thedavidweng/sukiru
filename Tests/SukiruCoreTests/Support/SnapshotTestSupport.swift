import CryptoKit
import Foundation

@testable import SukiruCore

/// A mutable queue feeding deterministic ids/dates to SnapshotStore's
/// injectable providers. Single-test use only (not thread-safe).
final class SnapshotProviderQueue<Value>: @unchecked Sendable {
    private var values: [Value]

    init(_ values: [Value]) {
        self.values = values
    }

    func next() -> Value {
        values.count > 1 ? values.removeFirst() : values[0]
    }
}

/// A built sandbox: fake home, project root, and its pre-run scan report.
struct SnapshotSandbox {
    let home: TempTree
    let project: TempTree
    let report: ScanReport
}

/// Shared builders for the SnapshotStore suites: deterministic stores, a
/// sandbox tree with both ledger files plus nested/symlinked payloads, and
/// direct CommandBatch construction (the store reads only id + findingRefs).
enum SnapshotTestSupport {
    static let baseDate = Date(timeIntervalSince1970: 1_758_000_000)

    /// A store over the given fake home with deterministic ids/dates.
    static func makeStore(
        home: String,
        ids: [String] = ["snap-1"],
        dates: [Date] = [baseDate],
        retention: Int = SnapshotStore.defaultRetentionLimit
    ) -> SnapshotStore {
        let idQueue = SnapshotProviderQueue(ids)
        let dateQueue = SnapshotProviderQueue(dates)
        let environment = SukiruEnvironment(
            reader: DictionaryEnvironmentReader(["SUKIRU_HOME": home]))
        return SnapshotStore(
            environment: environment,
            retentionLimit: retention,
            idProvider: { idQueue.next() },
            dateProvider: { dateQueue.next() })
    }

    /// `count` dates ascending in one-second steps from `baseDate`.
    static func dates(_ count: Int) -> [Date] {
        (0..<count).map { baseDate.addingTimeInterval(TimeInterval($0)) }
    }

    /// A sandbox: fake home with a global lock and the ownerless skill
    /// `orphan` (nested payload: subdirs, dotfile, internal + dangling
    /// symlinks, plus a `.claude` alias symlink), and a project root with a
    /// project lock and the lock-owned skill `tool`.
    static func makeTree() throws -> SnapshotSandbox {
        let home = try TempTree()
        let project = try TempTree()
        try home.file(".agents/.skill-lock.json", contents: OwnershipBuilders.globalLock([]))
        try home.file(
            ".agents/skills/orphan/SKILL.md", contents: OwnershipBuilders.skillMD("orphan"))
        try home.file(".agents/skills/orphan/scripts/run.sh", contents: "#!/bin/sh\necho hi\n")
        try home.file(".agents/skills/orphan/scripts/nested/deep.txt", contents: "deep")
        try home.file(".agents/skills/orphan/.hidden", contents: "dotfile")
        try home.symlink(".agents/skills/orphan/latest", to: "scripts")
        try home.symlink(".agents/skills/orphan/dangling", to: "missing-target")
        try home.symlink(".claude/skills/orphan", to: "../../.agents/skills/orphan")
        try project.file("skills-lock.json", contents: OwnershipBuilders.projectLock("tool"))
        try project.file(
            ".claude/skills/tool/SKILL.md", contents: OwnershipBuilders.skillMD("tool"))
        try project.file(".claude/skills/tool/notes.md", contents: "notes")
        let report = try OwnershipBuilders.scan(home: home, projectRoots: [project])
        return SnapshotSandbox(home: home, project: project, report: report)
    }

    /// A minimal batch carrying the given refs; commands are irrelevant to
    /// the store, which reads only `id` and `findingRefs`.
    static func batch(id: String = "batch-1", refs: [FindingRef]) -> CommandBatch {
        CommandBatch(
            id: id,
            createdAt: "2026-09-16T00:00:00Z",
            findingRefs: refs,
            decisions: [],
            commands: [],
            snapshotID: nil,
            status: .reviewed)
    }

    static func ref(_ id: String, skill: String, workspace: String) -> FindingRef {
        FindingRef(
            findingID: id, ruleID: "files-without-lock", skillName: skill, workspaceID: workspace)
    }

    /// Refs touching the user scope (`orphan`) and the project scope (`tool`).
    static func userAndProjectRefs(project: TempTree) -> [FindingRef] {
        var refs = [ref("f-orphan", skill: "orphan", workspace: "user")]
        refs.append(ref("f-tool", skill: "tool", workspace: "project:\(project.path)"))
        return refs
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
