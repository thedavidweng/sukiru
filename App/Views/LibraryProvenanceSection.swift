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
        Section {
            if isVercelReadOnly { readOnlyNotice }
            if skill.ambiguous { ambiguousNotice }
            if let vercel = skill.provenance.vercel, !hasCompanionRecord {
                field("Installer", String(localized: "Vercel skills CLI (lock entry)"))
                if let source = vercel.source { field("Source", source) }
                if let ref = vercel.ref { field("Ref", ref) }
                field(
                    "Version",
                    (vercel.updatedAt ?? vercel.installedAt).map(RecordTimestamp.display)
                        ?? String(localized: "unknown"))
            }
            if let github = skill.provenance.github {
                field("Installer", String(localized: "GitHub gh skill (frontmatter)"))
                field("Repository", github.repo)
                if let ref = github.ref { field("Ref", ref) }
                field("Version", github.treeSha ?? String(localized: "unknown"))
                pinStateRow(github)
                if let update = state.githubUpdate(for: skill) {
                    field(
                        "Update available",
                        [update.availableTree, update.ref.map { "(\($0))" }]
                            .compactMap { $0 }.joined(separator: " "))
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
                Text("No ledger claims this skill (ownerless).")
                    .foregroundStyle(.secondary)
            }
            LibraryLifecycleControls(skill: skill)
        } header: {
            TokenSectionHeader(token: "sukiru.library.detail.provenance", title: "Provenance")
        }
    }

    /// The skill's Vercel lock entry is gh's companion record, not a claim.
    private var hasCompanionRecord: Bool {
        skill.ownership == .github && skill.provenance.vercel?.githubCompanion == true
    }

    /// The Pin state row plus its actions: Pin… on an unpinned GitHub-ledger
    /// skill, Unpin on a pinned one. Both queue into Pending Changes; a
    /// queued change (any action) hides them, like the update controls.
    @ViewBuilder
    private func pinStateRow(_ github: GitHubProvenance) -> some View {
        let pinnedText =
            github.pinned
            ? github.pinnedRef.map { String(localized: "Pinned to \($0)") }
                ?? String(localized: "Pinned")
            : String(localized: "Unpinned")
        LabeledContent("Pin state") {
            HStack(spacing: 8) {
                Text(pinnedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(pinnedText)
                if skill.ownership == .github && state.queuedLifecycle(for: skill) == nil {
                    if github.pinned {
                        let unpinBlocked = state.lifecycleBlocker(.unpin, for: skill) != nil
                        Button("Unpin") {
                            state.queueLifecycle(.unpin, for: skill)
                        }
                        .controlSize(.small)
                        .disabled(unpinBlocked)
                        .axButtonToken("sukiru.library.detail.unpin", disabled: unpinBlocked)
                        .help("library.unpin.help")
                    } else {
                        let pinBlocked = state.lifecycleBlocker(.pin, for: skill) != nil
                        Button("Pin…") {
                            showingPinSheet = true
                        }
                        .controlSize(.small)
                        .disabled(pinBlocked)
                        .axButtonToken("sukiru.library.detail.pin", disabled: pinBlocked)
                        .help("Pin this skill to a tag, branch, or commit so updates skip it")
                    }
                }
            }
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
        // swiftlint:disable line_length
        let hint: LocalizedStringKey =
            "Read-only. Repairing, updating, or uninstalling this skill needs Node.js, which is not installed. Get it in Settings > Installers. Everything else still works."
        // swiftlint:enable line_length
        return HStack(spacing: 0) {
            AXToken(token: "sukiru.library.detail.readonly.\(AXTokens.skill(skill.name))")
            notice(hint)
        }
        .accessibilityElement(children: .contain)
    }

    private var ambiguousNotice: some View {
        // swiftlint:disable line_length
        let explanation: LocalizedStringKey =
            "Ownership ambiguous: distinct copies of this name disagree, so attribution is voided and the skill is treated as ownerless. Ledger claims below are data, not verdicts."
        // swiftlint:enable line_length
        return HStack(spacing: 0) {
            AXToken(token: "sukiru.library.detail.ambiguous.\(AXTokens.skill(skill.name))")
            notice(explanation)
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

    private func field(_ name: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(name) {
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
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
                Button("Queue Pin", action: queue)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!LifecycleRequest.isValidPinRef(trimmedRef))
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
