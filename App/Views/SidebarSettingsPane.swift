import SukiruCore
import SwiftUI

/// Which projects and hosts the sidebar shows, and in what order, like
/// Finder's Sidebar settings.
struct SidebarSettingsPane: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(SidebarArrangement.projectsKey) private var projects = SidebarArrangement.standard
    @AppStorage(SidebarArrangement.pluginHostsKey) private var pluginHosts =
        SidebarArrangement.standard
    @AppStorage(SidebarArrangement.hookHostsKey) private var hookHosts =
        SidebarArrangement.standard

    var body: some View {
        Form {
            if !state.projectRoots.isEmpty {
                SidebarArrangementSection(
                    "Projects", items: state.projectRoots.sorted(), arrangement: $projects,
                    identifier: "projects"
                ) { root in
                    Label {
                        Text(verbatim: URL(fileURLWithPath: root).lastPathComponent)
                            .help(root)
                    } icon: {
                        Image(systemName: "folder")
                    }
                }
            }
            SidebarArrangementSection(
                "Plugins", items: PluginHost.allCases, arrangement: $pluginHosts,
                identifier: "plugins", label: hostLabel)
            SidebarArrangementSection(
                "Hooks", items: PluginHost.hookHosts, arrangement: $hookHosts,
                identifier: "hooks",
                footer:
                    "Turn on the items to show in the sidebar. Drag them to change their order.",
                label: hostLabel)
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 480)
    }

    private func hostLabel(_ host: PluginHost) -> some View {
        Label {
            Text(verbatim: host.displayName)
        } icon: {
            AgentLogo(hostID: host.agentID, size: 16)
        }
    }
}

/// One sidebar section's rows. A grouped Form is not table-backed, so its
/// rows cannot use the system reordering (insertion line, row drag image); a
/// plain List inside the section can, and blends into the card.
private struct SidebarArrangementSection<Item: SidebarItem, RowLabel: View>: View {
    let title: LocalizedStringKey
    let items: [Item]
    @Binding var arrangement: SidebarArrangement
    let identifier: String
    let footer: LocalizedStringKey?
    @ViewBuilder let label: (Item) -> RowLabel

    init(
        _ title: LocalizedStringKey, items: [Item], arrangement: Binding<SidebarArrangement>,
        identifier: String, footer: LocalizedStringKey? = nil,
        @ViewBuilder label: @escaping (Item) -> RowLabel
    ) {
        self.title = title
        self.items = items
        self._arrangement = arrangement
        self.identifier = identifier
        self.footer = footer
        self.label = label
    }

    var body: some View {
        let arranged = arrangement.arranged(items)
        Section {
            List {
                ForEach(arranged, id: \.self) { item in
                    row(item, at: arranged.firstIndex(of: item) ?? 0, of: arranged.count)
                }
                .onMove { arrangement.move(items, from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: CGFloat(items.count) * 32)
        } header: {
            Text(title)
        } footer: {
            if let footer {
                Text(footer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The whole row drags through the List's native reordering; the handle
    /// only signals that it can.
    private func row(_ item: Item, at index: Int, of count: Int) -> some View {
        let shown = Binding(
            get: { arrangement.isShown(item) },
            set: { arrangement.set(item, shown: $0) })
        return HStack(spacing: 12) {
            label(item)
                .lineLimit(1)
            Spacer()
            Toggle("Show in Sidebar", isOn: shown)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityIdentifier("sukiru.settings.sidebar.\(identifier).\(item.sidebarID)")
                .help("Show this item in the sidebar")
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
                .help("Drag to change the order")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Move Up") { arrangement.move(items, from: [index], to: index - 1) }
                .disabled(index == 0)
            Button("Move Down") { arrangement.move(items, from: [index], to: index + 2) }
                .disabled(index == count - 1)
            Divider()
            Toggle("Show in Sidebar", isOn: shown)
        }
    }
}
