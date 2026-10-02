import SukiruCore
import SwiftUI

/// The installer records that claim a skill, shown as plain data; for an
/// ambiguous or capability-blocked skill the notices explain why those
/// records are not acted on.
struct LibraryProvenanceSection: View {
    @EnvironmentObject private var state: AppState

    let skill: Skill

    @State private var showingPinSheet = false

    var body: some View {
        // The No Known Source section already explains a plain ownerless
        // skill, so a section that would only repeat it is left out.
        if !isExplainedElsewhere {
            Section {
                rows
            } header: {
                TokenSectionHeader(token: "sukiru.library.detail.provenance", title: "Provenance")
            }
        }
    }

    @ViewBuilder
    private var rows: some View {
        if isVercelReadOnly { readOnlyNotice }
        if skill.ambiguous { ambiguousNotice }
        if let vercel = skill.provenance.vercel, !hasCompanionRecord {
            field("Installer", String(localized: "npx skills (Vercel)"))
            if let source = vercel.source { field("Source", source) }
            if let ref = vercel.ref { field("Ref", ref) }
            field(
                "Version",
                (vercel.updatedAt ?? vercel.installedAt).map(RecordTimestamp.display)
                    ?? String(localized: "unknown"))
        }
        if let github = skill.provenance.github {
            field("Installer", String(localized: "gh skill (GitHub)"))
            field("Repository", github.repo)
            if let ref = github.ref { field("Ref", ref) }
            field(
                "Version", github.treeSha.map(Self.short) ?? String(localized: "unknown"),
                help: github.treeSha)
            pinnedRow(github)
            if let update = state.githubUpdate(for: skill) {
                field("New Version", Self.short(update.availableTree), help: update.availableTree)
            }
        }
        if hasCompanionRecord {
            Text("library.githubCompanionRecord")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let agent = skill.managingAgent {
            Text("library.agentManaged \(agent)")
                .foregroundStyle(.secondary)
        } else if skill.provenance.vercel == nil && skill.provenance.github == nil {
            Text("No installer records this skill.")
                .foregroundStyle(.secondary)
        }
        LibraryLifecycleControls(skill: skill)
    }

    private var isExplainedElsewhere: Bool {
        skill.ownership == .ownerless && !skill.ambiguous && !isVercelReadOnly
            && skill.provenance.vercel == nil && skill.provenance.github == nil
            && state.orphanFinding(for: skill) != nil
    }

    /// A tree SHA shortened like `git log --oneline`, the full value in the
    /// tooltip.
    private static func short(_ sha: String) -> String {
        String(sha.prefix(7))
    }

    /// The skill's Vercel lock entry is gh's companion record, not a claim.
    private var hasCompanionRecord: Bool {
        skill.ownership == .github && skill.provenance.vercel?.githubCompanion == true
    }

    /// The Pinned row plus its action: Pin… on an unpinned GitHub-ledger
    /// skill, Unpin on a pinned one, each queued into Pending Changes. Like
    /// Restore Files, the action is hidden while gh writes are withheld or
    /// any change for the skill is queued.
    @ViewBuilder
    private func pinnedRow(_ github: GitHubProvenance) -> some View {
        let value =
            github.pinned
            ? github.pinnedRef ?? String(localized: "Yes")
            : String(localized: "No")
        let action: LifecycleAction = github.pinned ? .unpin : .pin
        let offered =
            skill.ownership == .github && state.queuedLifecycle(for: skill) == nil
            && state.lifecycleBlocker(action, for: skill) == nil
        LabeledContent("Pinned") {
            HStack(spacing: 8) {
                Text(value)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(value)
                if offered && github.pinned {
                    Button("Unpin") {
                        state.queueLifecycle(.unpin, for: skill)
                    }
                    .controlSize(.small)
                    .axButtonToken("sukiru.library.detail.unpin")
                    .help("library.unpin.help")
                } else if offered {
                    Button("Pin…") {
                        showingPinSheet = true
                    }
                    .controlSize(.small)
                    .axButtonToken("sukiru.library.detail.pin")
                    .help("Keep this skill at a tag, branch, or commit so updates skip it")
                }
            }
            .disabled(state.batchMutationInFlight)
        }
        .sheet(isPresented: $showingPinSheet) {
            PinSheet(skill: skill)
        }
    }

    private var isVercelReadOnly: Bool {
        guard let caps = state.capabilities, !caps.npx.canRunSkills else { return false }
        return skill.ownership == .vercel || skill.ownership == .doubleBooked
    }

    private var readOnlyNotice: some View {
        HStack(spacing: 0) {
            AXToken(token: "sukiru.library.detail.readonly.\(AXTokens.skill(skill.name))")
            notice("library.readOnly.needsNode")
        }
        .accessibilityElement(children: .contain)
    }

    private var ambiguousNotice: some View {
        HStack(spacing: 0) {
            AXToken(token: "sukiru.library.detail.ambiguous.\(AXTokens.skill(skill.name))")
            notice("library.ambiguous.explanation")
        }
        .accessibilityElement(children: .contain)
    }

    private func notice(_ text: LocalizedStringKey) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        }
    }

    private func field(
        _ name: LocalizedStringKey, _ value: String, help: String? = nil
    ) -> some View {
        LabeledContent(name) {
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(help ?? value)
        }
    }
}

/// The pin dialog: one ref field, queued into Pending Changes like every
/// other Library change (the batch confirmation is the review step). The
/// field starts at the recorded ref, stripped to the branch or tag name gh
/// `--pin` resolves.
private struct PinSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let skill: Skill
    @State private var ref: String

    init(skill: Skill) {
        self.skill = skill
        let recorded = skill.provenance.github?.ref ?? ""
        _ref = State(
            initialValue:
                recorded
                .replacingOccurrences(
                    of: "^refs/(heads|tags)/", with: "", options: .regularExpression))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pin \(skill.name)")
                .font(.headline)
            Text("library.pin.explanation")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Tag, branch, or commit SHA", text: $ref)
                .textFieldStyle(.roundedBorder)
                .onSubmit(queue)
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Pin", action: queue)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!LifecycleRequest.isValidPinRef(trimmedRef))
                    .help("Adds the pin to Pending Changes")
                    .axButtonToken(
                        "sukiru.library.detail.pin.queue",
                        disabled: !LifecycleRequest.isValidPinRef(trimmedRef))
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var trimmedRef: String {
        ref.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func queue() {
        guard LifecycleRequest.isValidPinRef(trimmedRef) else { return }
        state.queueLifecycle(.pin, for: skill, pinRef: trimmedRef)
        dismiss()
    }
}
