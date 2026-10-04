import Foundation

extension SnapshotStore {
    /// Captures explicit host file bounds without following links. Absent
    /// roots are represented by the pre-execution file inventory.
    func captureGeneric(roots: [String], staging: String) throws {
        var stored: [String: String] = [:]
        for (index, path) in Set(roots).sorted().enumerated() {
            let relative = "generic/\(index)"
            stored[path] = relative
            let captured = try RollbackFiles.capture(roots: [path])
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
