import Foundation
import SukiruCore

/// Localized messages for errors that reach the UI. Core errors carry
/// English `message`s for the CLI; the app renders each case itself and
/// keeps only machine detail (paths, ids, transport text) verbatim.
enum UserFacingError {
    static func message(for error: any Error) -> String {
        switch error {
        case let error as MarketplaceError: message(for: error)
        case let error as InstallPlanError: message(for: error)
        case let error as ExecutionError: message(for: error)
        case let error as BatchTransitionError: message(for: error)
        case let error as RollbackError: message(for: error)
        case let error as SnapshotError: message(for: error)
        case let error as BatchBuildError: message(for: error)
        default: fallback(for: error)
        }
    }

    private static func message(for error: MarketplaceError) -> String {
        switch error {
        case .transport(let detail):
            String(localized: "error.marketplace.transport \(detail)")
        case .malformed(let detail):
            String(localized: "error.marketplace.malformed \(detail)")
        }
    }

    private static func message(for error: InstallPlanError) -> String {
        switch error {
        case .missingRepo:
            String(localized: "error.install.missingRepo")
        case .malformedRepo(let repo):
            String(localized: "error.install.malformedRepo \(repo)")
        case .emptySkillName:
            String(localized: "error.install.emptySkillName")
        case .noSkillsSelected:
            String(localized: "error.install.noSkillsSelected")
        case .missingGHAgent:
            String(localized: "error.install.missingGHAgent")
        case .githubWriteWithheld(let skill, .touchesVercelRecord):
            String(localized: "error.install.githubTouchesVercelRecord \(skill)")
        case .githubWriteWithheld(let skill, _):
            String(localized: "error.install.githubDropsVercelLockData \(skill)")
        }
    }

    private static func message(for error: ExecutionError) -> String {
        switch error {
        case .notReviewed:
            String(localized: "error.execution.notReviewed")
        case .effectsNotApproved:
            String(localized: "error.execution.effectsNotApproved")
        case .busy:
            String(localized: "error.execution.busy")
        }
    }

    private static func message(for error: BatchTransitionError) -> String {
        switch error {
        case .illegalTransition(let from, let target):
            String(
                localized:
                    "error.batch.illegalTransition \(String(localized: from.title)) \(String(localized: target.title))"
            )
        }
    }

    private static func message(for error: RollbackError) -> String {
        switch error {
        case .invalidBatchID, .unknownBatch:
            String(localized: "error.rollback.unknownBatch")
        case .recordUnreadable:
            String(localized: "error.rollback.recordUnreadable")
        case .conflicts:
            String(localized: "rollback.conflicts.message")
        case .alreadyRolledBack:
            String(localized: "error.rollback.alreadyRolledBack")
        }
    }

    private static func message(for error: SnapshotError) -> String {
        switch error {
        case .captureFailed(let detail):
            String(localized: "error.snapshot.captureFailed \(detail)")
        case .invalidSnapshotID, .snapshotNotFound, .manifestUnreadable, .unsafeManifestEntry:
            String(localized: "error.snapshot.unreadable")
        }
    }

    /// Build problems are planner diagnostics: a localized lead line, then
    /// each problem verbatim.
    private static func message(for error: BatchBuildError) -> String {
        ([String(localized: "error.batch.buildFailed")] + error.problems)
            .joined(separator: "\n")
    }

    /// Cocoa and URL errors arrive localized by the system; anything else
    /// gets a localized lead line plus its technical description.
    private static func fallback(for error: any Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription {
            return description
        }
        let systemDomains = [
            NSCocoaErrorDomain, NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain
        ]
        if systemDomains.contains((error as NSError).domain) {
            return error.localizedDescription
        }
        return String(localized: "error.unexpected \(String(describing: error))")
    }
}
