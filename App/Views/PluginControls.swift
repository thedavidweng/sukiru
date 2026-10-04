import AppKit
import SukiruCore
import SwiftUI

/// The host's configured enablement as a switch. Flipping it only previews
/// the host's enable/disable command; the switch follows the host's state
/// after the reviewed batch runs and Sukiru rescans.
struct PluginEnabledToggle: View {
    @EnvironmentObject private var state: AppState
    let plugin: PluginInstallation

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { plugin.enablement == .enabled },
                set: { state.managePlugin(plugin, action: $0 ? "enable" : "disable") })
        ) {
            Text("Enabled in Host")
        }
        .toggleStyle(.switch)
        .disabled(state.pluginActionsBusy)
        .accessibilityIdentifier("sukiru.plugins.enabled.\(plugin.id)")
        .help("Preview the host's enable or disable command for this plugin")
    }
}

extension PluginInstallation {
    /// Enablement can be a switch only when the host toggles it and the
    /// current state is known.
    var offersEnabledToggle: Bool {
        enablement != .unknown && (actions.contains("enable") || actions.contains("disable"))
    }

    /// Actions shown as row buttons: the frequent ones, destructive last.
    var inlineActions: [String] {
        actions.filter { ["update", "disable-local", "remove"].contains($0) }
    }

    /// Everything not represented by the switch or the row buttons.
    var secondaryActions: [String] {
        actions.filter { !["enable", "disable", "remove"].contains($0) }
    }
}

/// Snapshots-style trailing controls for a plugin row.
struct PluginRowControls: View {
    @EnvironmentObject private var state: AppState
    let plugin: PluginInstallation

    var body: some View {
        HStack(spacing: 8) {
            if plugin.offersEnabledToggle {
                PluginEnabledToggle(plugin: plugin)
                    .labelsHidden()
                    .controlSize(.mini)
            } else if plugin.enablement != .unknown {
                Text(plugin.enablement.localizedTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(plugin.inlineActions, id: \.self) { action in
                Button(role: action == "remove" ? .destructive : nil) {
                    state.managePlugin(plugin, action: action)
                } label: {
                    Label(
                        PluginActionTitle.title(action),
                        systemImage: PluginActionTitle.symbol(action))
                }
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .disabled(state.pluginActionsBusy)
                .accessibilityIdentifier("sukiru.plugins.row.\(action).\(plugin.id)")
                .help(PluginActionTitle.title(action))
            }
        }
    }
}

/// A plugin row's context menu: lifecycle previews, then inspection and file
/// actions, then removal last.
struct PluginContextMenu: View {
    @EnvironmentObject private var state: AppState
    let plugin: PluginInstallation

    var body: some View {
        Section {
            if plugin.actions.contains("enable"), plugin.enablement != .enabled {
                actionButton("enable")
            }
            if plugin.actions.contains("disable"), plugin.enablement != .disabled {
                actionButton("disable")
            }
            ForEach(plugin.secondaryActions, id: \.self) { action in
                actionButton(action)
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
        if plugin.actions.contains("remove") {
            Section {
                Button(PluginActionTitle.title("remove") + "…", role: .destructive) {
                    state.managePlugin(plugin, action: "remove")
                }
            }
            .disabled(state.pluginActionsBusy)
        }
    }

    private func actionButton(_ action: String) -> some View {
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
