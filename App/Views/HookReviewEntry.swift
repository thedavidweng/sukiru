import Foundation
import SukiruCore
import SwiftUI

/// Immutable queued facts make each selected definition visible in the batch review.
struct HookReviewEntry: View {
    let hook: AgentHook

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(
                verbatim: hook.source.host.displayName + " · " + hook.event + " · "
                    + hook.handlerType)
            let matcher = hook.matcher ?? String(localized: "All Events")
            Text("hook.review.position \(hook.groupIndex) \(hook.handlerIndex) \(matcher)")
            Text(verbatim: hook.source.path)
            Text(verbatim: details)
        }
        .font(.caption)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var details: String {
        JSONValue.object(hook.details).hookDisplayValue
    }
}

/// A queued add, edit, or `disableAllHooks` change as it will be written.
struct HookChangeReviewEntry: View {
    let change: HookQueuedChange

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: change.changeTitle)
            if let event = change.request.event ?? change.hooks.first?.event {
                let matcher = change.request.matcher ?? String(localized: "All Events")
                Text(verbatim: event + " · " + matcher)
            }
            if let handler = change.request.handler {
                Text(verbatim: handler.command).font(.caption.monospaced())
                if let timeout = handler.timeout {
                    Text("hook.review.timeout \(timeout)")
                }
            }
        }
        .font(.caption)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension HookQueuedChange {
    var changeTitle: String {
        switch request.action {
        case "add": String(localized: "Add Hook")
        case "edit": String(localized: "Edit Hook")
        case "set-disable-all":
            if request.disableAllHooks == true {
                String(localized: "Disable All Hooks in This File")
            } else {
                String(localized: "Allow Hooks in This File")
            }
        case "set-hook-enabled":
            if request.enabled == true {
                String(localized: "Enable Hook")
            } else {
                String(localized: "Disable Hook")
            }
        case "remove-extension": String(localized: "Remove Extension")
        case "disable-extension": String(localized: "Disable Extension")
        case "enable-extension": String(localized: "Enable Extension")
        case "remove-leftovers": String(localized: "Producer Cleanup")
        default: String(localized: "Hook Cleanup")
        }
    }
}

extension JSONValue {
    var hookDisplayValue: String {
        switch self {
        case .string(let text): text
        case .bool(let flag): String(flag)
        case .int(let number): String(number)
        case .double(let number): String(number)
        case .null: "null"
        case .array(let values): "[" + values.map(\.hookDisplayValue).joined(separator: ", ") + "]"
        case .object(let fields):
            "{"
                + fields.keys.sorted().map { $0 + ": " + fields[$0]!.hookDisplayValue }
                .joined(separator: ", ") + "}"
        }
    }
}
