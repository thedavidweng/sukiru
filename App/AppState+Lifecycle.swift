import Foundation
import SukiruCore

/// Library updates and uninstalls of ledger-owned skills. They queue beside
/// Health repairs and check out in the same batch, so the same single
/// confirmation, snapshot, and rollback cover them.
@MainActor
extension AppState {
    func lifecycleBlocker(_ action: LifecycleAction, for skill: Skill) -> LifecycleBlocker? {
        CommandBatchBuilder.lifecycleBlocker(
            skill: skill, action: action, capabilities: capabilities, report: report)
    }

    func queuedLifecycle(for skill: Skill) -> LifecycleRequest? {
        let id = Self.skillID(skill)
        return lifecycleQueue.first { Self.skillID($0.skill) == id }
    }

    /// Queues an update or uninstall, replacing any earlier one for the skill.
    func queueLifecycle(_ action: LifecycleAction, for skill: Skill) {
        guard lifecycleBlocker(action, for: skill) == nil else { return }
        let id = Self.skillID(skill)
        lifecycleQueue.removeAll { Self.skillID($0.skill) == id }
        lifecycleQueue.append(LifecycleRequest(skill: skill, action: action))
    }

    func removeFromCart(_ request: LifecycleRequest) {
        lifecycleQueue.removeAll { $0 == request }
    }

    /// The skills Update All would queue: updatable and not yet queued.
    func updatableSkills(_ skills: [Skill]) -> [Skill] {
        skills.filter {
            lifecycleBlocker(.update, for: $0) == nil && queuedLifecycle(for: $0) == nil
        }
    }

    /// Update All: queues every updatable skill and checks out the whole
    /// cart, like Fix All. Installer-owned skills that cannot be updated
    /// here (a missing CLI, a cross-ledger write) are listed as not included.
    func updateAll(_ skills: [Skill]) {
        for skill in updatableSkills(skills) {
            queueLifecycle(.update, for: skill)
        }
        let withheld = withheldUpdates(skills)
        checkout()
        fixSkipped += withheld
    }

    /// Why each installer-owned skill among `skills` cannot be updated here.
    func withheldUpdates(_ skills: [Skill]) -> [String] {
        skills.compactMap { skill in
            guard skill.ownership == .vercel || skill.ownership == .github,
                let blocker = lifecycleBlocker(.update, for: skill)
            else { return nil }
            return blocker.refusal(.update, skill: skill)
        }
    }

    /// Drops the Library changes a succeeded batch carried; failed ones
    /// stay queued for another try.
    func dequeueLifecycle(completedBy batch: CommandBatch, status: BatchStatus?) {
        guard status == .succeeded else { return }
        let done = Set(batch.findingRefs.map(\.findingID))
        lifecycleQueue.removeAll { done.contains($0.id) }
    }
}
