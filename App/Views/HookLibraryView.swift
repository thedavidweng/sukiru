import SukiruCore
import SwiftUI

struct HookLibraryView: View {
    @Environment(AppState.self) private var state
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
        @Bindable var state = state
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
        .navigationTitle(Text(verbatim: state.hookState.host.displayName))
        .navigationSubtitle(Text("\(hooks.count) hooks"))
        .overlay {
            if hooks.isEmpty && issues.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView(
                        "No hooks found", systemImage: "bolt.horizontal",
                        description: Text("This host's settings declare no hooks."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .searchable(text: $search, prompt: "Filter Hooks")
        .accessibilityIdentifier("sukiru.hooks.list")
        .help("Inspect configured hooks; scanning never executes them")
        .toolbar {
            ColumnAction {
                Button {
                    state.hookState.editor = .add(state.hookState.host)
                } label: {
                    Label("Add Hook…", systemImage: "plus")
                }
                .disabled(!canAddHooks || state.batchMutationInFlight)
                .accessibilityIdentifier("sukiru.hooks.add")
                .help("Queue a new command hook in a settings file for review")
            }
        }
        .sheet(item: $state.hookState.editor) { target in
            HookEditorSheet(target: target)
        }
    }

    private var issues: [HookInventoryIssue] {
        state.report?.hookInventory?.issues.filter { $0.host == state.hookState.host } ?? []
    }

    private var canAddHooks: Bool {
        [.claude, .codex].contains(state.hookState.host) && state.report?.hookInventory != nil
    }

    @ViewBuilder
    private func hookSection(_ title: LocalizedStringKey, entries: [AgentHook]) -> some View {
        if !entries.isEmpty {
            Section {
                let byScope = Dictionary(grouping: entries, by: \.source.scopeRoot)
                ForEach(byScope.keys.sorted(), id: \.self) { root in
                    Section {
                        ForEach(byScope[root] ?? []) { hook in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(verbatim: hook.event).fontWeight(.semibold)
                                    Spacer()
                                    Text(hook.health.title).font(.caption).foregroundStyle(
                                        .secondary)
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
                    } header: {
                        ListSectionHeader(
                            title: Text(
                                root == state.environment.home
                                    ? String(localized: "User scope")
                                    : URL(fileURLWithPath: root).lastPathComponent
                            )
                            .help(root),
                            count: byScope[root]?.count ?? 0)
                    }
                }
            } header: {
                ListSectionHeader(title: Text(title), count: entries.count)
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
