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

    /// Pin (or Unpin, once pinned) is a gh write, so it is offered only
    /// when nothing would withhold it and no change is already queued.
    func offersPinChange(for skill: Skill) -> Bool {
        guard skill.ownership == .github, let github = skill.provenance.github else {
            return false
        }
        return queuedLifecycle(for: skill) == nil
            && lifecycleBlocker(github.pinned ? .unpin : .pin, for: skill) == nil
    }

    func offersRestore(for skill: Skill) -> Bool {
        skill.ownership == .github && lifecycleBlocker(.restore, for: skill) == nil
    }

    func queuedLifecycle(for skill: Skill) -> LifecycleRequest? {
        let id = Self.skillID(skill)
        return lifecycleQueue.first { Self.skillID($0.skill) == id }
    }

    /// Queues an update, uninstall, pin, unpin, or restore, replacing any
    /// earlier one for the skill. A pin without a valid ref is refused.
    func queueLifecycle(_ action: LifecycleAction, for skill: Skill, pinRef: String? = nil) {
        guard lifecycleBlocker(action, for: skill) == nil else { return }
        if action == .pin {
            guard let pinRef, LifecycleRequest.isValidPinRef(pinRef) else { return }
        }
        let id = Self.skillID(skill)
        lifecycleQueue.removeAll { Self.skillID($0.skill) == id }
        lifecycleQueue.append(LifecycleRequest(skill: skill, action: action, pinRef: pinRef))
    }

    /// The skills in the Library's selected scope, before any filter: a
    /// filter only narrows the view, so updates still cover the whole scope.
    var skillsInLibraryScope: [Skill] {
        report?.skills.filter(isInLibraryScope) ?? []
    }

    func isInLibraryScope(_ skill: Skill) -> Bool {
        switch libraryScope {
        case .all: true
        case .user: skill.scope == .user
        case .project(let root): skill.scope == .project && projectRoot(of: skill) == root
        }
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

    /// Drops the Library changes a succeeded batch carried, host removals
    /// included; failed ones stay queued for another try.
    func dequeueLifecycle(completedBy batch: CommandBatch, status: BatchStatus?) {
        guard status == .succeeded else { return }
        let done = Set(batch.findingRefs.map(\.findingID))
        lifecycleQueue.removeAll { done.contains($0.id) }
        hostRemovalQueue.removeAll { done.contains($0.id) }
    }
}
