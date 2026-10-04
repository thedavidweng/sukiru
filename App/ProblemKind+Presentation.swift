import SukiruCore
import SwiftUI

/// Plain-language copy for each Health problem: what it is, why it matters,
/// and what the one-click fix does.
extension ProblemKind {
    var title: LocalizedStringKey {
        switch self {
        case .staleLockEntry: "Lock lists skills that are gone"
        case .missingSharedCopy: "Shared copies are missing"
        case .deadLink: "Dead links"
        case .copyInsteadOfLink: "Copies instead of links"
        case .outOfSync: "Copies out of sync"
        case .leftoverHostDir: "Leftover folders of uninstalled agents"
        case .orphan: "Skills with no known source"
        case .ownerConflict: "Conflicting owners"
        case .duplicateName: "Duplicate skill names"
        case .unsupportedLock: "Lock from a newer installer"
        case .note: "Notes"
        }
    }

    var explanation: LocalizedStringKey {
        switch self {
        case .staleLockEntry:
            "problem.staleLockEntry.explanation"
        case .missingSharedCopy:
            "problem.missingSharedCopy.explanation"
        case .deadLink:
            "problem.deadLink.explanation"
        case .copyInsteadOfLink:
            "problem.copyInsteadOfLink.explanation"
        case .outOfSync:
            "problem.outOfSync.explanation"
        case .leftoverHostDir:
            "problem.leftoverHostDir.explanation"
        case .orphan:
            "problem.orphan.explanation"
        case .ownerConflict:
            "problem.ownerConflict.explanation"
        case .duplicateName:
            "problem.duplicateName.explanation"
        case .unsupportedLock:
            "problem.unsupportedLock.explanation"
        case .note:
            "problem.note.explanation"
        }
    }

    var symbol: String {
        switch self {
        case .staleLockEntry: "list.bullet.rectangle"
        case .missingSharedCopy: "externaldrive.badge.questionmark"
        case .deadLink: "link"
        case .copyInsteadOfLink: "doc.on.doc"
        case .outOfSync: "arrow.triangle.2.circlepath"
        case .leftoverHostDir: "folder.badge.minus"
        case .orphan: "questionmark.folder"
        case .ownerConflict: "person.2"
        case .duplicateName: "doc.on.doc"
        case .unsupportedLock: "lock.trianglebadge.exclamationmark"
        case .note: "note.text"
        }
    }
}

extension DecisionAction {
    /// The one name a repair goes by everywhere: the Health fix button, the
    /// Pending Changes decision panel, and the Repair menu.
    var title: LocalizedStringResource {
        switch self {
        case .cleanup: "Remove"
        case .relink: "Link to Shared Copy"
        case .update: "Reinstall"
        case .adopt: "Adopt into GitHub Ledger…"
        case .arbitrate: "Choose Owner…"
        case .leave: "Leave As-Is"
        }
    }
}

extension AppState.CartItem {
    /// What the queued repair will do, naming the chosen source or owner.
    var title: String {
        switch choice {
        case .adoptVercel(let source):
            let shown = source.hasPrefix("https://") ? String(source.dropFirst(8)) : source
            return String(localized: "Adopt from \(shown)")
        case .adoptSource(let repo, _):
            return String(localized: "Adopt from \(repo)")
        case .keepVercel:
            return String(localized: "Keep Vercel Ledger")
        case .keepGitHub:
            return String(localized: "Keep GitHub Ledger")
        case nil:
            return String(localized: action.title)
        }
    }
}
