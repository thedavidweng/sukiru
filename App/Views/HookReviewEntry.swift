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
