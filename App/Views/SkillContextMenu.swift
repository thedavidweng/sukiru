import AppKit
import SukiruCore
import SwiftUI

/// A Library row's context menu: the same changes the skill's detail offers,
/// each queued into Pending Changes, then file actions, then the destructive
/// one last. Items the detail hides because they can never apply here are
/// hidden here too; Update and Uninstall stay visible but disabled.
struct SkillContextMenu: View {
    @EnvironmentObject private var state: AppState

    let skill: Skill

    var body: some View {
        Section {
            changeItems
        }
        .disabled(state.batchMutationInFlight)
        Section {
            if !state.findingEntries(for: skill).isEmpty {
                Button("Show in Health") {
                    state.showFindings(for: skill)
                }
            }
            if let path = skill.placements.first?.path {
                Button("Show in Finder") {
                    state.revealInFinder([path])
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
        }
        Section {
            destructiveItem
        }
        .disabled(state.batchMutationInFlight)
    }

    private var isLedgerOwned: Bool {
        skill.ownership == .vercel || skill.ownership == .github
    }

    private var orphanFinding: Finding? { state.orphanFinding(for: skill) }

    @ViewBuilder
    private var changeItems: some View {
        if let request = state.queuedLifecycle(for: skill) {
            Button("Remove from Pending Changes") {
                state.removeFromCart(request)
            }
        } else if let item = orphanFinding.flatMap(state.cartItem(for:)) {
            Button("Remove from Pending Changes") {
                state.removeFromCart(item)
            }
        } else if isLedgerOwned {
            Button("Update") {
                state.queueLifecycle(.update, for: skill)
            }
            .disabled(state.lifecycleBlocker(.update, for: skill) != nil)
            pinItem
            if state.offersRestore(for: skill) {
                Button("Restore Files") {
                    state.queueLifecycle(.restore, for: skill)
                }
            }
        } else if orphanFinding != nil {
            Button("Find Source…") {
                state.findSource(for: skill)
            }
            .disabled(!state.canAdoptFromSource)
        }
    }

    @ViewBuilder
    private var pinItem: some View {
        if state.offersPinChange(for: skill), let github = skill.provenance.github {
            if github.pinned {
                Button("Unpin") {
                    state.queueLifecycle(.unpin, for: skill)
                }
            } else {
                Button("Pin…") {
                    state.pinSheetSkill = skill
                }
            }
        }
    }

    @ViewBuilder
    private var destructiveItem: some View {
        let queued =
            state.queuedLifecycle(for: skill) != nil
            || orphanFinding.flatMap(state.cartItem(for:)) != nil
        if !queued && isLedgerOwned {
            Button("Uninstall", role: .destructive) {
                state.queueLifecycle(.uninstall, for: skill)
            }
            .disabled(state.lifecycleBlocker(.uninstall, for: skill) != nil)
        } else if !queued && orphanFinding != nil {
            Button("Queue Deletion", role: .destructive) {
                state.deleteOrphan(skill)
            }
        }
    }
}

/// Group actions are available only when every selected skill supports them.
struct SkillsSelectionActions: View {
    @EnvironmentObject private var state: AppState
    let skills: [Skill]

    var body: some View {
        Section {
            Button("Update") { queue(.update) }
                .disabled(!canQueue(.update))
                .accessibilityIdentifier("sukiru.library.selection.update")
                .help("Update")
            if skills.allSatisfy({ state.offersRestore(for: $0) }) {
                Button("Restore Files") { queue(.restore) }
                    .disabled(!canQueue(.restore))
                    .accessibilityIdentifier("sukiru.library.selection.restore")
                    .help("Restore Files")
            }
            if skills.allSatisfy({ $0.provenance.github?.pinned == true }) {
                Button("Unpin") { queue(.unpin) }
                    .disabled(!canQueue(.unpin))
                    .accessibilityIdentifier("sukiru.library.selection.unpin")
                    .help("Unpin")
            }
            if skills.allSatisfy(hasQueuedChange) {
                Button("Remove from Pending Changes") {
                    for skill in skills {
                        if let request = state.queuedLifecycle(for: skill) {
                            state.removeFromCart(request)
                        }
                        let orphan = state.orphanFinding(for: skill)
                        if let item = orphan.flatMap(state.cartItem(for:)) {
                            state.removeFromCart(item)
                        }
                    }
                }
                .accessibilityIdentifier("sukiru.library.selection.unqueue")
                .help("Remove from Pending Changes")
            }
        }
        .disabled(state.batchMutationInFlight)
        Section {
            let paths = skills.compactMap { $0.placements.first?.path }
            Button("Show in Finder") { state.revealInFinder(paths) }
                .disabled(paths.isEmpty)
                .accessibilityIdentifier("sukiru.library.selection.reveal")
                .help("Show in Finder")
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
            }
            .disabled(paths.isEmpty)
            .accessibilityIdentifier("sukiru.library.selection.copy")
            .help("Copy Path")
        }
        Section {
            Button("Uninstall", role: .destructive) {
                for skill in skills {
                    if state.orphanFinding(for: skill) != nil {
                        state.deleteOrphan(skill)
                    } else {
                        state.queueLifecycle(.uninstall, for: skill)
                    }
                }
            }
            .disabled(
                !skills.allSatisfy {
                    !hasQueuedChange($0)
                        && (state.orphanFinding(for: $0) != nil
                            || state.lifecycleBlocker(.uninstall, for: $0) == nil)
                }
            )
            .accessibilityIdentifier("sukiru.library.selection.uninstall")
            .help("Uninstall")
        }
        .disabled(state.batchMutationInFlight)
    }

    private func hasQueuedChange(_ skill: Skill) -> Bool {
        state.queuedLifecycle(for: skill) != nil
            || state.orphanFinding(for: skill).flatMap(state.cartItem(for:)) != nil
    }

    private func canQueue(_ action: LifecycleAction) -> Bool {
        !skills.isEmpty
            && skills.allSatisfy {
                !hasQueuedChange($0) && state.lifecycleBlocker(action, for: $0) == nil
            }
    }

    private func queue(_ action: LifecycleAction) {
        for skill in skills { state.queueLifecycle(action, for: skill) }
    }
}
