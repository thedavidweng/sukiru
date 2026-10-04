import AppKit
import SukiruCore
import SwiftUI

/// The host's configured enablement as a switch, the same in every host's
/// list and in the inspector. Flipping it only previews the host's command;
/// the switch follows the host's state after the reviewed batch runs and
/// Sukiru rescans. A host with no command for a direction shows the switch
/// dimmed, like a setting managed elsewhere.
struct PluginEnabledToggle: View {
    @EnvironmentObject private var state: AppState
    let plugin: PluginInstallation

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { plugin.switchIsOn },
                set: { isOn in
                    if let action = plugin.switchAction(turningOn: isOn) {
                        state.managePlugin(plugin, action: action)
                    }
                })
        ) {
            Text("Enabled in Host")
        }
        .toggleStyle(.switch)
        .disabled(state.pluginActionsBusy || !plugin.switchIsChangeable)
        .accessibilityIdentifier("sukiru.plugins.enabled.\(plugin.id)")
        .help(
            plugin.switchIsChangeable
                ? "Preview the host's enable or disable command for this plugin"
                : "This host has no command to change whether this plugin is enabled")
    }
}

extension PluginInstallation {
    /// The switch shows the host's configured state; an OpenCode file found
    /// in a discovery folder is on by being there.
    var offersEnabledSwitch: Bool {
        enablement != .unknown || actions.contains("disable-local")
    }

    var switchIsOn: Bool { enablement != .disabled }

    var switchIsChangeable: Bool { switchAction(turningOn: !switchIsOn) != nil }

    func switchAction(turningOn: Bool) -> String? {
        (turningOn ? ["enable"] : ["disable", "disable-local"]).first(where: actions.contains)
    }

    /// Everything not represented by the switch or the inspector's toolbar.
    var secondaryActions: [String] {
        actions.filter { !["enable", "disable", "disable-local", "update", "remove"].contains($0) }
    }
}

/// The plugin list's context menu. One plugin gets lifecycle previews, then
/// inspection and file actions, then removal last; a multiple selection gets
/// the actions that apply to all of it.
struct PluginContextMenu: View {
    @EnvironmentObject private var state: AppState
    let plugins: [PluginInstallation]

    var body: some View {
        if plugins.count == 1, let plugin = plugins.first {
            single(plugin)
        } else if !plugins.isEmpty {
            let paths = plugins.compactMap(\.path)
            if !paths.isEmpty {
                Button("Show in Finder") { state.revealInFinder(paths) }
            }
            removeSection
        }
    }

    @ViewBuilder
    private func single(_ plugin: PluginInstallation) -> some View {
        Section {
            if plugin.actions.contains("enable"), plugin.enablement != .enabled {
                actionButton(plugin, "enable")
            }
            if plugin.actions.contains("disable"), plugin.enablement != .disabled {
                actionButton(plugin, "disable")
            }
            ForEach(
                plugin.actions.filter { !["enable", "disable", "remove"].contains($0) },
                id: \.self
            ) { action in
                actionButton(plugin, action)
            }
        }
        .disabled(state.pluginActionsBusy)
        Section {
            if state.report?.pluginInventory?.healthFindings.contains(where: {
                $0.pluginID == plugin.id
            }) == true {
                Button("Show in Health") { state.surface = .health }
            }
            if let path = plugin.path {
                Button("Show in Finder") { state.revealInFinder([path]) }
                Button("Copy Path") { copy(path) }
            }
            Button("Copy Identifier") { copy(plugin.identifier) }
        }
        removeSection
    }

    @ViewBuilder
    private var removeSection: some View {
        let removable = plugins.filter { $0.actions.contains("remove") }
        if !removable.isEmpty {
            Section {
                Button(role: .destructive) {
                    state.removePlugins(removable)
                } label: {
                    if removable.count == 1 {
                        Text(PluginActionTitle.title("remove") + "…")
                    } else {
                        Text("Remove \(removable.count) Plugins…")
                    }
                }
            }
            .disabled(state.pluginActionsBusy)
        }
    }

    private func actionButton(_ plugin: PluginInstallation, _ action: String) -> some View {
        Button(PluginActionTitle.title(action) + "…") {
            state.managePlugin(plugin, action: action)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension AppState {
    var pluginActionsBusy: Bool { batchMutationInFlight || pluginManagement.planning }
}
