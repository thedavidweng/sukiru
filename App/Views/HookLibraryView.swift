import SukiruCore
import SwiftUI

struct HookLibraryView: View {
    @EnvironmentObject private var state: AppState
    @State private var search = ""

    private var hooks: [AgentHook] {
        state.hooks(for: state.hookState.host).filter {
            search.isEmpty
                || [
                    $0.event, $0.source.path, state.hookProducerTitle($0),
                    $0.details["command"]?.stringValue ?? ""
                ].contains {
                    $0.localizedCaseInsensitiveContains(search)
                }
        }
    }

    var body: some View {
        List(selection: $state.hookState.selectedID) {
            hookSection("Needs Attention", entries: hooks.filter { $0.health.isProblem })
            hookSection(
                "Managed Hooks",
                entries: hooks.filter {
                    !$0.health.isProblem && [.externallyManaged, .sourceManaged].contains($0.health)
                })
            hookSection(
                "Other Hooks",
                entries: hooks.filter {
                    !$0.health.isProblem
                        && ![.externallyManaged, .sourceManaged].contains($0.health)
                })
            let issues =
                state.report?.hookInventory?.issues.filter { $0.host == state.hookState.host } ?? []
            if !issues.isEmpty {
                Section("Inspection Issues") {
                    ForEach(issues) { issue in
                        VStack(alignment: .leading) {
                            Text(verbatim: issue.message)
                            Text(verbatim: issue.path).font(.caption).foregroundStyle(.secondary)
                            Button("Show in Finder") { state.revealInFinder([issue.path]) }
                                .accessibilityIdentifier("sukiru.hooks.issue.reveal.\(issue.id)")
                                .help("Reveal the hook source without changing it")
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle("Hooks")
        .navigationSubtitle(Text(verbatim: state.hookState.host.displayName))
        .searchable(text: $search, prompt: "Filter Hooks")
        .accessibilityIdentifier("sukiru.hooks.list")
        .help("Inspect configured hooks; scanning never executes them")
    }

    @ViewBuilder
    private func hookSection(_ title: LocalizedStringKey, entries: [AgentHook]) -> some View {
        if !entries.isEmpty {
            Section(title) {
                let byScope = Dictionary(grouping: entries, by: \.source.scopeRoot)
                ForEach(byScope.keys.sorted(), id: \.self) { root in
                    Section(
                        root == state.environment.home ? String(localized: "User Library") : root
                    ) {
                        ForEach(byScope[root] ?? []) { hook in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(verbatim: hook.event)
                                    Spacer()
                                    Text(hook.health.title).foregroundStyle(.secondary)
                                }
                                Text(
                                    verbatim: state.hookProducerTitle(hook) + " · "
                                        + hook.handlerType
                                )
                                .font(.callout)
                                Text(verbatim: hook.source.tier + " · " + hook.source.path)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .tag(hook.id)
                            .accessibilityIdentifier("sukiru.hooks.row.\(hook.id)")
                        }
                    }
                }
            }
        }
    }
}

extension HookHealth {
    var title: LocalizedStringKey {
        switch self {
        case .observed: "Configured"
        case .brokenTarget: "Broken Target"
        case .leftover: "Leftover"
        case .externallyManaged: "Externally Managed"
        case .sourceManaged: "Source Managed"
        case .invalid: "Invalid Hook"
        case .unknown: "Unknown"
        }
    }
}
