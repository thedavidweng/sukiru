import Foundation

extension SnapshotStore {
    /// Captures explicit host file bounds without following links. Absent
    /// roots are represented by the pre-execution file inventory. A root already
    /// inside another root's copy is stored once, under that ancestor; one reached
    /// through a link is not inside it and keeps its own copy.
    func captureGeneric(roots: [String], staging: String) throws {
        var inventories: [(root: String, files: RollbackFiles)] = []
        var covered = Set<String>()
        // Sorting places every ancestor before its descendants.
        for path in Set(roots).sorted() where !covered.contains(path) {
            let captured = try RollbackFiles.capture(roots: [path])
            covered.formUnion(captured.entries.keys)
            inventories.append((path, captured))
        }
        try Self.checkCaptureSize(inventories.map { ($0.root, $0.files.entries.count) })
        var stored: [String: String] = [:]
        for (index, (path, captured)) in inventories.enumerated() {
            let relative = "generic/\(index)"
            stored[path] = relative
            guard captured.entries[path] != nil else { continue }
            // Raw link targets are stored in before.json; copying protected
            // system-link metadata is unnecessary for byte/identity restoration.
            if captured.entries[path]?.kind == "link" { continue }
            let destination = HostPathResolver.join(staging, relative)
            // Validate every entry before copying: unsupported file kinds
            // and read failures must stop the batch before execution.
            try FileManager.default.createDirectory(
                atPath: HostPathResolver.join(staging, "generic"), withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(atPath: path, toPath: destination)
        }
        try deterministicJSONData(stored).write(
            to: URL(fileURLWithPath: HostPathResolver.join(staging, "generic.json")),
            options: .atomic)
    }

    static let captureEntryLimit = 50_000

    /// Refuses a batch whose roots would expand into a snapshot too large to keep.
    static func checkCaptureSize(_ counts: [(root: String, entries: Int)]) throws {
        let total = counts.reduce(0) { $0 + $1.entries }
        guard total > captureEntryLimit, let largest = counts.max(by: { $0.entries < $1.entries })
        else { return }
        throw SnapshotError.captureFailed(
            "\(total) files exceed the snapshot limit of \(captureEntryLimit); "
                + "the largest capture root is \(largest.root) (\(largest.entries) files)")
    }

    static func genericRoots(snapshotDirectory: String) throws -> [String: String] {
        let bytes = try Data(
            contentsOf: URL(
                fileURLWithPath:
                    HostPathResolver.join(snapshotDirectory, "generic.json")))
        return try JSONDecoder().decode([String: String].self, from: bytes)
    }

    static func genericSources(snapshotDirectory: String) throws -> [String: String] {
        let roots = try genericRoots(snapshotDirectory: snapshotDirectory)
        let before = try RollbackFiles.load(from: snapshotDirectory, name: "before.json")
        var sources: [String: String] = [:]
        for (path, relative) in roots {
            try Self.validateStoredPath(relative, snapshotID: snapshotDirectory)
            let stored = HostPathResolver.join(snapshotDirectory, relative)
            let directory = before.entries[path]?.kind == "directory"
            for entry in before.entries.keys
            where entry == path || (directory && entry.hasPrefix(path + "/")) {
                sources[entry] = stored + entry.dropFirst(path.count)
            }
        }
        return sources
    }
}
