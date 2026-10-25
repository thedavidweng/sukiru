import SukiruCore
import SwiftUI

struct PnpmObservationSection: View {
    let observations: [PnpmObservation]

    var body: some View {
        Section {
            ForEach(observations, id: \.identity) { observation in
                DisclosureGroup {
                    LabeledContent("Permission", value: permissionText(observation.permission))
                    Text(
                        observation.installed
                            ? "Verified skill links are installed" : "No verified skill links")
                    Text("Permission applies to every skill in this package.")
                        .foregroundStyle(.secondary)
                    Text(verbatim: observation.selector).font(.callout.monospaced())
                        .textSelection(.enabled)
                    Text(verbatim: observation.projectRoot).textSelection(.enabled)
                    Text(verbatim: observation.metadataPath).font(.callout.monospaced())
                        .textSelection(.enabled)
                    Text("Review package permissions with pnpm, then refresh Sukiru.")
                        .foregroundStyle(.secondary)
                } label: {
                    LabeledContent {
                        Text(permissionText(observation.permission)).foregroundStyle(.secondary)
                    } label: {
                        Text(verbatim: observation.packageName)
                    }
                }
                .accessibilityIdentifier(
                    "sukiru.health.pnpm.\(AXTokens.path(observation.identity))"
                )
                .accessibilityValue(permissionText(observation.permission))
                .help("Inspect package-wide permission and verified installation evidence")
            }
        } header: {
            Text("pnpm Package Permissions")
                .accessibilityIdentifier("sukiru.health.pnpm")
        }
    }

    private func permissionText(_ permission: PnpmObservation.Permission) -> String {
        switch permission {
        case .pending: String(localized: "Awaiting Approval")
        case .approved: String(localized: "Approved")
        case .denied: String(localized: "Denied")
        case .unknown: String(localized: "Unknown Permission")
        }
    }
}

extension AppState {
    var visiblePnpmObservations: [PnpmObservation] {
        guard healthFocus == nil else { return [] }
        return (report?.pnpmObservations ?? []).filter {
            healthWorkspaceFilter == nil || healthWorkspaceFilter == "project:" + $0.projectRoot
        }
    }
}
