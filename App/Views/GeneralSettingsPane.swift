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
                ForEach(pluginHosts.hosts, id: \.self) { host in
                    pluginHostRow(host)
                        .pluginHostDraggable(host)
                }
                .dropDestination(for: String.self) { pluginHosts.drop($0, at: $1) }
                ForEach(pluginHosts.hiddenHosts, id: \.self) { pluginHostRow($0) }
            } header: {
                Text("Sidebar Plugins")
            } footer: {
                Text("Drag hosts here or in the sidebar to change their order.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 360)
        .onChange(of: language) { _, newValue in
            AppLanguage.override = newValue
        }
    }

    private func pluginHostRow(_ host: PluginHost) -> some View {
        Toggle(
            isOn: Binding(
                get: { pluginHosts.hosts.contains(host) },
                set: { pluginHosts.set(host, pinned: $0) })
        ) {
            Label {
                Text(verbatim: host.displayName)
            } icon: {
                AgentLogo(hostID: host.agentID, size: 16)
            }
        }
        .accessibilityIdentifier("sukiru.settings.sidebarPlugins.\(host.rawValue)")
        .help("Show this host's plugins in the sidebar")
    }
}
