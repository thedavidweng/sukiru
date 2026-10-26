import SukiruCore
import SwiftUI

/// Add Hook / Edit: one command handler in a documented standalone source.
/// Nothing is written here; the change joins Pending Changes for review (ADR-0014).
struct HookEditorSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let target: HookEditorTarget

    @State private var scope = HookScopeChoice(scope: "user", root: "")
    @State private var event = ""
    @State private var matcher = ""
    @State private var command = ""
    @State private var timeout: Int?
    @State private var statusMessage = ""
    @State private var failure: String?

    private var editedHook: AgentHook? {
        if case .edit(let hook) = target { return hook }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editedHook == nil ? LocalizedStringKey("Add Hook") : "Edit Hook")
                .font(.headline)
            Form {
                LabeledContent("Host", value: target.host.displayName)
                if let hook = editedHook {
                    LabeledContent("Event", value: hook.event)
                    LabeledContent("Source", value: hook.source.path)
                } else {
                    scopePicker
                    Picker("Event", selection: $event) {
                        ForEach(HookEvents.documented(for: target.host), id: \.self) {
                            Text(verbatim: $0).tag($0)
                        }
                    }
                    .accessibilityIdentifier("sukiru.hooks.editor.event")
                    .help("The lifecycle event that runs this hook")
                }
                TextField("Matcher", text: $matcher, prompt: Text("All Events"))
                    .accessibilityIdentifier("sukiru.hooks.editor.matcher")
                    .help("hook.editor.matcher.help")
                LabeledContent("Command") {
                    TextEditor(text: $command)
                        .font(.body.monospaced())
                        .frame(minHeight: 72)
                        .accessibilityIdentifier("sukiru.hooks.editor.command")
                        .help("The shell command the host runs for this hook")
                }
                TextField(
                    "Timeout (seconds)", value: $timeout, format: .number, prompt: Text("Default")
                )
                .accessibilityIdentifier("sukiru.hooks.editor.timeout")
                .help("Leave empty to use the host's default timeout")
                if target.host == .codex {
                    TextField("Status Message", text: $statusMessage, prompt: Text("None"))
                        .accessibilityIdentifier("sukiru.hooks.editor.statusMessage")
                        .help("The message Codex shows while the hook runs")
                }
            }
            .formStyle(.grouped)
            if target.host == .codex {
                Text("hook.editor.codexTrust")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure {
                Text(verbatim: failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(24)
        .frame(width: 560)
        .onAppear(perform: prefill)
    }

    private var scopePicker: some View {
        Picker("Scope", selection: $scope) {
            ForEach(scopeChoices, id: \.self) { choice in
                Text(verbatim: title(of: choice)).tag(choice)
            }
        }
        .accessibilityIdentifier("sukiru.hooks.editor.scope")
        .help("The settings file that receives the hook")
    }

    private var scopeChoices: [HookScopeChoice] {
        var choices = [HookScopeChoice(scope: "user", root: "")]
        for root in state.projectRoots {
            choices.append(HookScopeChoice(scope: "project", root: root))
            if target.host == .claude {
                choices.append(HookScopeChoice(scope: "local", root: root))
            }
        }
        return choices
    }

    private func title(of choice: HookScopeChoice) -> String {
        let name = URL(fileURLWithPath: choice.root).lastPathComponent
        switch choice.scope {
        case "project": return String(localized: "hook.scope.project \(name)")
        case "local": return String(localized: "hook.scope.local \(name)")
        default: return String(localized: "User Library")
        }
    }

    private var buttons: some View {
        let blocked =
            command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || state.batchMutationInFlight
        return HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("sukiru.hooks.editor.cancel")
                .help("Close without queuing a change")
            Button("Add to Pending Changes") { queue() }
                .keyboardShortcut(.defaultAction)
                .disabled(blocked)
                .accessibilityIdentifier("sukiru.hooks.editor.queue")
                .help("Review this hook change with other queued changes before it is written")
        }
    }

    private func prefill() {
        guard let hook = editedHook else {
            event = HookEvents.documented(for: target.host).first ?? ""
            return
        }
        matcher = hook.matcher ?? ""
        command = hook.details["command"]?.stringValue ?? ""
        timeout = hook.details["timeout"]?.intValue
        statusMessage = hook.details["statusMessage"]?.stringValue ?? ""
    }

    private func queue() {
        let handler = HookHandlerSpec(
            command: command.trimmingCharacters(in: .newlines), timeout: timeout,
            statusMessage: target.host == .codex && !statusMessage.isEmpty ? statusMessage : nil)
        let request: HookCleanupRequest
        if let hook = editedHook {
            request = HookCleanupRequest(
                action: "edit", hookID: hook.id, matcher: matcher, handler: handler)
        } else {
            request = HookCleanupRequest(
                action: "add", host: target.host, scope: scope.scope,
                scopeRoot: scope.scope == "user" ? nil : scope.root, event: event,
                matcher: matcher, handler: handler)
        }
        do {
            try state.queueHookChange(request, hooks: editedHook.map { [$0] } ?? [])
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}

struct HookScopeChoice: Hashable {
    let scope: String
    let root: String
}
