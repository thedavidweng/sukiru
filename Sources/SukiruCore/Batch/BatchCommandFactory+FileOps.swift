import Foundation

/// Direct file-operation commands for placements no official CLI can repair
/// (ADR-0007). Each is danger-flagged, snapshot-protected by the batch
/// pipeline, and never writes a ledger.
extension BatchCommandFactory {
    /// Deletes a symlink whose target is gone (or an ownerless skill's
    /// link). `npx skills remove` only deletes names its lock records, so a
    /// dead link with no lock entry has no CLI path.
    static func deleteLink(name: String, path: String, intent: String) -> BatchCommand {
        fileOperation(
            .deleteLink(path),
            display: "delete link " + BatchCommand.display(for: [path]),
            intent: intent,
            flags: [.directFileOperation],
            warning: "Direct removal of the link '\(path)' for '\(name)'. The link is "
                + "captured in the batch snapshot.")
    }

    /// Replaces a host-folder copy with a link to the shared-store copy.
    /// `diverged` marks a copy whose content differs from the store's, so
    /// its local edits are discarded (kept only in the snapshot).
    static func relink(
        name: String, path: String, storePath: String, diverged: Bool, intent: String
    ) -> BatchCommand {
        var warning = "Direct file operation: '\(path)' becomes a link to '\(storePath)'."
        if diverged {
            warning +=
                " This copy differs from the shared copy; its changes are kept "
                + "only in the batch snapshot."
        }
        return fileOperation(
            .relink(path: path, target: storePath),
            display: "link " + BatchCommand.display(for: [path]) + " → "
                + BatchCommand.display(for: [storePath]),
            intent: intent,
            flags: diverged
                ? [.directFileOperation, .discardsLocalChanges] : [.directFileOperation],
            warning: warning)
    }

    /// Replaces a link with an independent copy of the directory it points
    /// to.
    static func materialize(name: String, path: String, intent: String) -> BatchCommand {
        fileOperation(
            .materialize(path),
            display: "copy into " + BatchCommand.display(for: [path]),
            intent: intent,
            flags: [.directFileOperation],
            warning: "Direct file operation: the link '\(path)' becomes a standalone copy "
                + "of '\(name)'. Later updates to the shared copy no longer reach it.")
    }

    private static func fileOperation(
        _ operation: FileOperation, display: String, intent: String,
        flags: [DangerFlag], warning: String
    ) -> BatchCommand {
        BatchCommand(
            argv: operation.argv,
            displayString: display + " (direct file operation)",
            owningCLI: .file,
            intent: intent,
            dangerFlags: flags,
            warning: warning)
    }
}
