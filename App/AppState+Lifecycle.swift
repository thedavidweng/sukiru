import Foundation
import SukiruCore

/// Library updates and uninstalls of ledger-owned skills. They queue beside
/// Health repairs and check out in the same batch, so the same single
/// confirmation, snapshot, and rollback cover them.
@MainActor
extension AppState {
    func lifecycleBlocker(_ action: LifecycleAction, for skill: Skill) -> LifecycleBlocker? {
        CommandBatchBuilder.lifecycleBlocker(
            skill: skill, action: action, capabilities: capabilities)
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
    /// cart, like Fix All.
    func updateAll(_ skills: [Skill]) {
        for skill in updatableSkills(skills) {
            queueLifecycle(.update, for: skill)
        }
        checkout()
    }

    /// Drops the Library changes a succeeded batch carried; failed ones
    /// stay queued for another try.
    func dequeueLifecycle(completedBy batch: CommandBatch, status: BatchStatus?) {
        guard status == .succeeded else { return }
        let done = Set(batch.findingRefs.map(\.findingID))
        lifecycleQueue.removeAll { done.contains($0.id) }
    }
}
