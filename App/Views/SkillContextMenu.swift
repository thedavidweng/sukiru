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
