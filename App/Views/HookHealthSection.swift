import SwiftUI

struct HookHealthSection: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Section("Hook Problems") {
            ForEach(state.visibleHookProblems) { hook in
                DisclosureGroup {
                    Text(verbatim: hook.source.path)
                    ForEach(hook.evidence, id: \.self) { Text(verbatim: $0) }
                    Button("Inspect Hook") { state.inspectHook(hook) }
                        .accessibilityIdentifier("sukiru.health.hooks.inspect.\(hook.id)")
                        .help("Inspect the handler, producer evidence, and cleanup options")
                } label: {
                    HStack {
                        Text(verbatim: hook.source.host.displayName + " · " + hook.event)
                        Spacer()
                        Text(hook.health.title).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("sukiru.health.hooks.\(hook.id)")
                .help("Inspect a statically diagnosed hook problem")
            }
            ForEach(state.visibleHookIssues) { issue in
                VStack(alignment: .leading) {
                    Text(verbatim: issue.message)
                    Text(verbatim: issue.path).font(.caption).foregroundStyle(.secondary)
                    Button("Show in Finder") { state.revealInFinder([issue.path]) }
                        .accessibilityIdentifier("sukiru.health.hooks.issue.\(issue.id)")
                        .help("Inspect malformed or unsupported hook configuration in Finder")
                }
            }
        }
    }
}
