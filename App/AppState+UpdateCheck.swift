import Foundation
import SukiruCore

/// The last gh update check: available updates by `AppState.skillID`,
/// whether a check runs, and the folders it could not check.
struct UpdateCheckState {
    var updates: [String: GitHubUpdate] = [:]
    var running = false
    var failures: [String] = []
}

/// Checking GitHub-ledger skills for upstream updates. The check is gh's own
/// read-only dry run, so it runs outside any batch, like search and listing.
@MainActor
extension AppState {
    func canCheckGitHubUpdates(_ skills: [Skill]) -> Bool {
        capabilities?.github.available == true
            && !GitHubUpdateChecker.checkable(skills).isEmpty
    }

    /// Runs the check off the main actor. A skill checked again loses its
    /// earlier result; results for other skills stay.
    func checkGitHubUpdates(_ skills: [Skill]) {
        guard canCheckGitHubUpdates(skills), !updateCheck.running else { return }
        let checked = GitHubUpdateChecker.checkable(skills)
        let checker = GitHubUpdateChecker(environment: environment)
        updateCheck.running = true
        updateCheck.failures = []
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = checker.check(checked)
            await self?.applyGitHubUpdateCheck(result, checked: checked)
        }
    }

    private func applyGitHubUpdateCheck(_ result: GitHubUpdateCheck, checked: [Skill]) {
        updateCheck.running = false
        for skill in checked {
            updateCheck.updates[Self.skillID(skill)] = nil
        }
        for found in result.updates {
            updateCheck.updates[Self.skillID(found.skill)] = found.update
        }
        updateCheck.failures = result.failures
    }

    /// The update last found for `skill`, unless the skill has changed on
    /// disk since (an update ran, or someone edited its record).
    func githubUpdate(for skill: Skill) -> GitHubUpdate? {
        guard let update = updateCheck.updates[Self.skillID(skill)],
            update.installedTreeSha == skill.provenance.github?.treeSha
        else { return nil }
        return update
    }
}
