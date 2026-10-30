import SukiruCore
import SwiftUI

/// One host's add-ons: auto-loaded extensions, packages, plugins, or MCP servers. Sukiru
/// never loads their code.
struct ExtensionLibraryView: View {
    @EnvironmentObject private var state: AppState

    private var host: ExtensionHost { state.hookState.extensionHost }
    private var items: [AgentExtension] {
        state.extensions(for: host, mcp: state.hookState.showsMCP)
    }
    private var categories: [ExtensionCategory] {
        host.categories.filter { ($0 == .mcpServer) == state.hookState.showsMCP }
    }

    var body: some View {
        List(selection: $state.hookState.selectedExtensionID) {
            ForEach(categories, id: \.self) { category in
                section(category.title, items.filter { $0.category == category })
            }
        }
        .listStyle(.inset)
        .navigationTitle(state.hookState.showsMCP ? "MCP Servers" : "Extensions")
        .navigationSubtitle(Text(verbatim: host.displayName))
        .accessibilityIdentifier("sukiru.extensions.list")
        .help("Inspect what this host loads; scanning never runs it")
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(
                    state.hookState.showsMCP ? "No MCP Servers" : "No Extensions",
                    systemImage: "puzzlepiece.extension",
                    description: Text("This host's user configuration declares none."))
            }
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ entries: [AgentExtension]) -> some View {
        if !entries.isEmpty {
            Section(title) {
                ForEach(entries) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(verbatim: item.name)
                            Spacer()
                            if item.enabled == false {
                                Text("Disabled").foregroundStyle(.secondary)
                            }
                            if let action = state.queuedExtensionAction(item) {
                                Text(action.queuedTitle).foregroundStyle(.orange)
                            }
                        }
                        if item.producer != "Unknown" {
                            Text(verbatim: item.producer).font(.callout)
                        }
                        Text(verbatim: item.detail ?? item.path)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(item.id)
                    .accessibilityIdentifier("sukiru.extensions.row.\(item.id)")
                }
            }
        }
    }
}

struct ExtensionDetailView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let item = state.selectedExtension {
            Form {
                Section(item.category.title) {
                    LabeledContent("Host", value: item.host.displayName)
                    LabeledContent("Name", value: item.name)
                    LabeledContent("Status") { Text(item.statusTitle) }
                    LabeledContent("Kind") { Text(item.kind.title) }
                    if let scope = item.scopeName, item.category != .mcpServer {
                        LabeledContent("Declared In", value: scope)
                    }
                    if let detail = item.detail {
                        LabeledContent("Source") {
                            Text(verbatim: detail).font(.callout.monospaced())
                        }
                    }
                    LabeledContent("Producer", value: item.producer)
                    Text(verbatim: item.path).font(.callout.monospaced())
                    ForEach(item.evidence, id: \.self) { Text(verbatim: $0) }
                }
                Section("Actions") {
                    Button("Show in Finder") { state.revealInFinder([item.path]) }
                        .accessibilityIdentifier("sukiru.extensions.reveal")
                        .help("Reveal the entry without running it")
                    if let limit = item.toggleLimit {
                        Text(verbatim: limit).font(.callout).foregroundStyle(.secondary)
                    } else {
                        if item.enabled != false {
                            Button("Queue Disable") { state.queueExtension(item, action: .disable) }
                                .disabled(state.batchMutationInFlight)
                                .accessibilityIdentifier("sukiru.extensions.disable")
                                .help(
                                    "Queue the host's command or documented switch that turns this off"
                                )
                        }
                        if item.enabled != true {
                            Button("Queue Enable") { state.queueExtension(item, action: .enable) }
                                .disabled(state.batchMutationInFlight)
                                .accessibilityIdentifier("sukiru.extensions.enable")
                                .help(
                                    "Queue the host's command or documented switch that turns this on"
                                )
                        }
                    }
                    Button("Queue Removal", role: .destructive) { state.queueExtension(item) }
                        .disabled(state.batchMutationInFlight)
                        .accessibilityIdentifier("sukiru.extensions.remove")
                        .help("Queue this exact entry for reviewed, snapshot-protected removal")
                    if state.producerLeftovers.contains(where: { $0.producer == item.producer }) {
                        Button("Queue Producer Leftovers", role: .destructive) {
                            state.queueHookProducer(item.producer, disable: false)
                        }
                        .disabled(state.batchMutationInFlight)
                        .accessibilityIdentifier("sukiru.extensions.removeProducer")
                        .help("Review every hook, extension, and helper this producer left behind")
                    }
                }
            }
            .formStyle(.grouped)
            .textSelection(.enabled)
        } else {
            ContentUnavailableView(
                "Select an entry to inspect it", systemImage: "puzzlepiece.extension")
        }
    }
}

extension AgentExtension {
    var statusTitle: LocalizedStringKey {
        switch enabled {
        case true?: "Enabled"
        case false?: "Disabled"
        case nil: "Unknown"
        }
    }

    var toggleLimit: String? { HookCleanupPlanner.toggleLimit(self) }
}

extension ExtensionAction {
    var queuedTitle: LocalizedStringKey {
        switch self {
        case .remove: "Removal Queued"
        case .disable: "Disable Queued"
        case .enable: "Enable Queued"
        }
    }
}

extension AgentExtension.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .file: "File"
        case .directory: "Folder"
        case .link: "Link"
        case .enabledEntry: "Enabled Entry"
        case .configEntry: "Configuration Entry"
        }
    }
}
