import Foundation
import SukiruCore

/// Localized labels for the execution and rollback vocabulary, whose raw
/// values are record-file tokens rather than UI copy.
extension BatchStatus {
    var title: LocalizedStringResource {
        switch self {
        case .proposed: "Proposed"
        case .reviewed: "Reviewed"
        case .executing: "Executing"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .rolledBack: "Rolled Back"
        }
    }
}

extension CommandExecutionStatus {
    var title: LocalizedStringResource {
        switch self {
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .timedOut: "Timed Out"
        case .notRun: "Not Run"
        }
    }
}

extension RestoreItem.Category {
    var title: LocalizedStringResource {
        switch self {
        case .restoredFromSnapshot: "Restored from snapshot"
        case .deletedBatchAdded: "Removed (added by the batch)"
        case .unrestorableWithReason: "Could not restore"
        }
    }
}

enum RecordTimestamp {
    /// Record and lock timestamps are ISO 8601 strings, with or without
    /// fractional seconds; show them in the user's locale, falling back to
    /// the raw string if one does not parse.
    static func display(_ raw: String) -> String {
        let date =
            (try? Date(raw, strategy: .iso8601))
            ?? (try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        guard let date else { return raw }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}
