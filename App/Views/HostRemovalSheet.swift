import SukiruCore
import SwiftUI

/// Remove Skills from Agent: pick one concrete scope and one Agent Host,
/// review what the official CLI would remove, keep, and leave visible, then
/// queue the request in Pending Changes. Nothing runs from here; checkout
/// rebuilds the request against fresh disk evidence and asks for the usual
/// single confirmation (ADR 0012).
struct HostRemovalSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var bucket = "user"
    @State private var hostID: String?
    /// Captured once per presentation, after the scan the sheet opened on.
    @State private var context: HostRemovalContext?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 0) {
                AXToken(token: "sukiru.library.hostRemoval.title")
                Text("Remove Skills from Agent")
                    .font(.headline)
            }
            Text("hostRemoval.explanation")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                Picker("Scope", selection: $bucket) {
                    ForEach(state.hostRemovalBuckets, id: \.self) { bucket in
                        Text(verbatim: state.hostRemovalScopeTitle(bucket)).tag(bucket)
                    }
                }
                .accessibilityIdentifier("sukiru.library.hostRemoval.scope")
                Picker("Agent", selection: $hostID) {
                    Text("Choose an Agent").tag(String?.none)
                    ForEach(candidates, id: \.id) { host in
                        Text(verbatim: host.displayName).tag(String?.some(host.id))
                    }
                }
                .disabled(candidates.isEmpty)
                .accessibilityIdentifier("sukiru.library.hostRemoval.host")
            }
            if candidates.isEmpty {
                Text("hostRemoval.noHosts")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let plan {
                HostRemovalPreview(plan: plan)
            }
            buttons
        }
        .padding(24)
        .frame(width: 600)
        .onAppear {
            context = state.makeHostRemovalContext()
            bucket = initialBucket
        }
        .onChange(of: bucket) {
            hostID = nil
        }
    }

    private var initialBucket: String {
        switch state.libraryScope {
        case .all, .user: "user"
        case .project(let root): "project:" + root
        }
    }

    private var candidates: [HostSpec] {
        guard let report = state.report, let context else { return [] }
        return CommandBatchBuilder().hostRemovalCandidates(
            bucket: bucket, report: report, context: context)
    }

    private var plan: HostRemovalPlan? {
        guard let hostID, let report = state.report, let context else { return nil }
        return try? CommandBatchBuilder().planHostRemoval(
            hostID: hostID, bucket: bucket, report: report, context: context,
            capabilities: state.capabilities)
    }

    private var buttons: some View {
        let queued = plan.map { state.queuedHostRemoval(hostID: $0.hostID, bucket: $0.bucket) }
        let blocked =
            (plan.map { !$0.problems.isEmpty || queued == $0.request } ?? true)
            || state.batchMutationInFlight
        return HStack {
            Spacer()
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .axButtonToken("sukiru.library.hostRemoval.cancel")
            Button("Add to Pending Changes") {
                if let plan {
                    state.queueHostRemoval(plan)
                }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(blocked)
            .axButtonToken("sukiru.library.hostRemoval.queue", disabled: blocked)
            .help("hostRemoval.queue.help")
        }
    }
}

/// The plan's three lists and its consequences, in the order the CLI
/// preview prints them.
private struct HostRemovalPreview: View {
    @EnvironmentObject private var state: AppState

    let plan: HostRemovalPlan

    private var hostName: String {
        HostTable.host(id: plan.hostID)?.displayName ?? plan.hostID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !plan.removed.isEmpty {
                        GroupBox("Removed (\(plan.removed.count))") {
                            entries(plan.removed.map { PreviewRow(name: $0.name, path: $0.path) })
                        }
                    }
                    if !plan.leftInPlace.isEmpty {
                        GroupBox("Left in Place (\(plan.leftInPlace.count))") {
                            entries(
                                plan.leftInPlace.map {
                                    PreviewRow(
                                        name: $0.entry.name, path: $0.entry.path,
                                        note: $0.reason.localizedText)
                                })
                        }
                    }
                    if !plan.stillVisible.isEmpty {
                        GroupBox("Still Visible (\(plan.stillVisible.count))") {
                            entries(
                                plan.stillVisible.map {
                                    PreviewRow(name: $0.name, path: $0.sourceFolder)
                                })
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
            consequences
            problems
        }
    }

    private func entries(_ rows: [PreviewRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: row.name)
                        .font(.callout.weight(.medium))
                    Text(verbatim: row.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = row.note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var consequences: some View {
        if !plan.sharedCopyDeletions.isEmpty {
            Label {
                Text(
                    "hostRemoval.sharedCopyDeletion \(plan.sharedCopyDeletions.formatted(.list(type: .and)))"
                )
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
            .font(.callout)
        }
        if plan.predictionUncertain {
            Label {
                Text("hostRemoval.predictionUncertain")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "questionmark.circle")
            }
            .font(.callout)
        }
        if plan.settingHint != nil {
            Label {
                Text("hostRemoval.openCodeHint")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.callout)
        }
    }

    /// The core's blocking problems, localized from the plan's own facts.
    @ViewBuilder private var problems: some View {
        if plan.removed.isEmpty {
            if plan.leftInPlace.contains(where: { $0.reason == .sharedFolder }) {
                Text("hostRemoval.problem.sharedFolder \(hostName)")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("hostRemoval.problem.nothingRemovable \(hostName)")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if state.capabilities?.npx.canRunSkills == false {
            Text("hostRemoval.problem.needsNode")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PreviewRow {
    let name: String
    let path: String
    var note: LocalizedStringResource?
}

extension HostRemovalReason {
    var localizedText: LocalizedStringResource {
        switch self {
        case .ownerless: "hostRemoval.reason.ownerless"
        case .githubLedger: "hostRemoval.reason.githubLedger"
        case .agentManaged: "hostRemoval.reason.agentManaged"
        case .ambiguous: "hostRemoval.reason.ambiguous"
        case .sharedFolder: "hostRemoval.reason.sharedFolder"
        case .unofficialEntry: "hostRemoval.reason.unofficialEntry"
        }
    }
}
