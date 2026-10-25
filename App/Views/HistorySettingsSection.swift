import SukiruCore
import SwiftUI

/// The retention limits for snapshots and execution records, shared with the
/// CLI through `settings.json`, plus current usage and "Clear History…".
struct HistorySettingsSection: View {
    @EnvironmentObject private var state: AppState
    @State private var policy = RetentionPolicy.default
    @State private var usage = HistoryUsage(batches: 0, bytes: 0)
    @State private var loaded = false
    @State private var confirmingClear = false

    private static let sizeChoices = [256, 512, 1024, 2048, 5120, 10240]

    var body: some View {
        Section {
            Stepper(value: $policy.maxBatches, in: 1...500) {
                Text("Keep at most \(policy.maxBatches) batches")
            }
            Stepper(value: $policy.maxAgeDays, in: 1...365) {
                Text("Remove batches older than \(policy.maxAgeDays) days")
            }
            Picker("Keep history under", selection: $policy.maxSizeMegabytes) {
                ForEach(sizeChoices, id: \.self) { megabytes in
                    Text(verbatim: Self.sizeText(megabytes: megabytes)).tag(megabytes)
                }
            }
            LabeledContent("Batches Kept", value: "\(usage.batches)")
            LabeledContent(
                "Storage Used",
                value: ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file))
            Button("Clear History…", role: .destructive) {
                confirmingClear = true
            }
            .disabled(state.batchMutationInFlight || usage.batches == 0)
        } header: {
            Text("History")
        } footer: {
            Text("history.limits.footer")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog("Clear All History?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { state.clearHistory() }
        } message: {
            Text("history.clear.message")
        }
        .task { await load() }
        .onChange(of: policy) { _, newValue in
            guard loaded else { return }
            try? SukiruSettingsStore(environment: environment).save(newValue)
        }
        .onChange(of: state.batchMutationInFlight) { _, _ in
            Task { await refreshUsage() }
        }
    }

    private var environment: SukiruEnvironment {
        AppState.makeEnvironment(roots: state.projectRoots)
    }

    private var sizeChoices: [Int] {
        Set(Self.sizeChoices + [policy.maxSizeMegabytes]).sorted()
    }

    private static func sizeText(megabytes: Int) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(megabytes) * 1_048_576, countStyle: .binary)
    }

    private func load() async {
        policy = SukiruSettingsStore(environment: environment).retentionPolicy()
        await refreshUsage()
        loaded = true
    }

    private func refreshUsage() async {
        let environment = environment
        usage = await Task.detached(priority: .utility) {
            HistoryRetention(environment: environment).usage()
        }.value
    }
}
