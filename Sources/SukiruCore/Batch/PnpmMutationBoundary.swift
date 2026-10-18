import Foundation

extension CommandBatchBuilder {
    /// Installer operations use either the original name or the entry's
    /// folder name. Both can reach a package-manager placement.
    static func protectsPnpm(
        name: String?, bucket: String, paths: [String] = [], report: ScanReport
    ) -> Bool {
        report.skills.contains { skill in
            guard skill.isPnpmReadOnly, Self.bucket(of: skill, report: report) == bucket else {
                return false
            }
            if name == skill.name { return true }
            return skill.placements.contains { placement in
                let folder = (placement.path as NSString).lastPathComponent
                // Installer callers may provide the concrete pnpm placement folder.
                if let name, name == folder || HostRemovalContext.folderName(name) == folder {
                    return true
                }
                return paths.contains { path in
                    path == placement.path || placement.path.hasPrefix(path + "/")
                        || path == placement.canonicalPath
                }
            }
        }
    }
}
