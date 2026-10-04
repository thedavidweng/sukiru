import SukiruCore
import SwiftUI

struct HookDetailView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let hook = state.selectedHook {
            Form {
                Section("Hook") {
                    LabeledContent("Host", value: hook.source.host.displayName)
                    LabeledContent("Event", value: hook.event)
                    LabeledContent(
                        "Matcher", value: hook.matcher ?? String(localized: "All Events"))
                    LabeledContent("Handler", value: hook.handlerType)
                    LabeledContent("Health") { Text(hook.health.title) }
                    LabeledContent("Scope", value: hook.source.scope)
                    LabeledContent("Source Tier", value: hook.source.tier)
                    Text(verbatim: hook.source.path).font(.callout.monospaced())
                    if hook.source.host == .codex {
                        LabeledContent(
                            "Hook Trust", value: String(localized: "Unknown — Review in Codex"))
                    }
                    Text("Configured hooks do not establish runtime execution or success.")
                        .foregroundStyle(.secondary)
                }
                Section("Handler Details") {
                    ForEach(hook.details.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: hook.details[key]!.hookDisplayValue)
                    }
                }
                Section("Attribution Evidence") {
                    LabeledContent("Producer", value: state.hookProducerTitle(hook))
                    ForEach(hook.attribution.evidence + hook.evidence, id: \.self) { evidence in
                        Text(verbatim: evidence)
                    }
                    ForEach(hook.targets, id: \.self) { path in
                        Button {
                            state.revealInFinder([path])
                        } label: {
                            Text(verbatim: path)
                        }
                        .accessibilityIdentifier("sukiru.hooks.target.\(path)")
                        .help("Reveal the literal hook target in Finder")
                    }
                }
                HookActions(hook: hook)
            }
            .formStyle(.grouped)
            .textSelection(.enabled)
        } else {
            ContentUnavailableView(
                "Select a hook to inspect it", systemImage: "bolt.horizontal.circle")
        }
    }

}

struct HookActions: View {
    @EnvironmentObject private var state: AppState
    let hook: AgentHook

    private var managingPlugin: PluginInstallation? {
        state.report?.pluginInventory?.installations.first { $0.id == hook.source.managingPluginID }
    }

    private var managingSkill: Skill? {
        state.report?.skills.first { skill in
            skill.placements.contains { hook.source.managingSource == $0.path + "/SKILL.md" }
        }
    }

    private var offersOrcaDisable: Bool {
        hook.attribution.producer == "Orca" && hook.attribution.producerPresent == true
            && hook.source.writable && state.orcaHookDisableAvailable
    }

    var body: some View {
        Section("Actions") {
            Button("Show in Finder") { state.revealInFinder([hook.source.path]) }
                .accessibilityIdentifier("sukiru.hooks.reveal")
                .help("Reveal the authoritative hook source without executing it")
            if let plugin = managingPlugin {
                Button("Show Managing Plugin") {
                    state.pluginHost = plugin.host
                    state.selectedPluginID = plugin.id
                    state.surface = .plugins
                }
                .accessibilityIdentifier("sukiru.hooks.plugin")
                .help("Manage this hook through its plugin lifecycle")
            }
            if let skill = managingSkill {
                Button("Show Managing Skill") {
                    state.libraryScope = .all
                    state.selectedSkillID = AppState.skillID(skill)
                    state.surface = .library
                }
                .accessibilityIdentifier("sukiru.hooks.skill")
                .help("Inspect the skill that defines this hook")
            }
            if offersOrcaDisable {
                Button("Queue Orca Hook Disable") { state.queueHookProducer("Orca", disable: true) }
                    .disabled(state.batchMutationInFlight)
                    .accessibilityIdentifier("sukiru.hooks.disableOrca")
                    .help("Review Orca's supported disable command across hosts in Pending Changes")
            } else if hook.canRemove {
                if hook.attribution.producerPresent == true {
                    Text(
                        "The installed producer may recreate this hook. Disable the integration in the producer first."
                    )
                    .foregroundStyle(.secondary)
                }
                Button("Queue Hook Removal", role: .destructive) { state.queueHook(hook) }
                    .disabled(state.batchMutationInFlight)
                    .accessibilityIdentifier("sukiru.hooks.remove")
                    .help("Queue this exact handler for reviewed, snapshot-protected removal")
            } else {
                Text(
                    "This hook is read-only. Manage it through its source unit or policy administrator."
                )
                .foregroundStyle(.secondary)
            }
            if hook.health == .leftover, hook.attribution.producerPresent == false, hook.canRemove {
                Button("Queue Producer Leftovers", role: .destructive) {
                    state.queueHookProducer(hook.attribution.producer, disable: false)
                }
                .disabled(state.batchMutationInFlight)
                .accessibilityIdentifier("sukiru.hooks.removeProducer")
                .help("Review every exact hook entry and removable helper for this producer")
            }
        }
    }
}
