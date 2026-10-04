import SukiruCore
import SwiftUI

/// App-wide preferences, such as the UI language override and which hosts'
/// plugins the sidebar shows.
struct GeneralSettingsPane: View {
    @AppStorage(SidebarPluginHosts.defaultsKey) private var pluginHosts = SidebarPluginHosts.all
    @State private var language = AppLanguage.override

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $language) {
                    Text("System Default").tag(String?.none)
                    Divider()
                    ForEach(AppLanguage.available, id: \.self) { identifier in
                        Text(verbatim: AppLanguage.displayName(identifier))
                            .tag(Optional(identifier))
                    }
                }
            } footer: {
                if AppLanguage.needsRelaunch(for: language) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Sukiru switches to the new language after it relaunches.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Relaunch Now") {
                            AppLanguage.relaunch()
                        }
                    }
                }
            }
            Section {
                // A grouped Form is not table-backed, so its rows cannot use
                // the system reordering (insertion line, row drag image). A
                // plain List inside the section can, and blends into the card.
                List {
                    ForEach(pluginHosts.order, id: \.self) { host in
                        SidebarPluginHostRow(host: host, hosts: $pluginHosts)
                    }
                    .onMove { pluginHosts.move(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: CGFloat(PluginHost.allCases.count) * 32)
            } header: {
                Text("Sidebar Plugins")
            } footer: {
                Text(
                    "Turn on the hosts to show in the sidebar. Drag them to change their order."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 320)
        .onChange(of: language) { _, newValue in
            AppLanguage.override = newValue
        }
    }
}

/// One host in Sidebar Plugins. The whole row drags through the List's
/// native reordering; the handle only signals that it can.
private struct SidebarPluginHostRow: View {
    let host: PluginHost
    @Binding var hosts: SidebarPluginHosts

    var body: some View {
        let index = hosts.order.firstIndex(of: host) ?? 0
        HStack(spacing: 12) {
            Label {
                Text(verbatim: host.displayName)
            } icon: {
                AgentLogo(hostID: host.agentID, size: 16)
            }
            Spacer()
            Toggle("Show in Sidebar", isOn: shown)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityIdentifier("sukiru.settings.sidebarPlugins.\(host.rawValue)")
                .help("Show this host's plugins in the sidebar")
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
                .help("Drag to change the order")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Move Up") { hosts.move(host, to: hosts.order[index - 1]) }
                .disabled(index == 0)
            Button("Move Down") { hosts.move(host, to: hosts.order[index + 1]) }
                .disabled(index == hosts.order.count - 1)
            Divider()
            Toggle("Show in Sidebar", isOn: shown)
        }
    }

    private var shown: Binding<Bool> {
        Binding(
            get: { !hosts.hidden.contains(host) },
            set: { hosts.set(host, pinned: $0) })
    }
}
