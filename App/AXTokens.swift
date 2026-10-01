import SwiftUI

/// Accessibility-label token grammar support.
///
/// The computer-use tree (orca) exposes accessibility LABELS, not
/// identifiers, and its text dump prints one string per element: a static
/// text prints its label (when set) else its content; a button prints only
/// its AX value; a list row prints its children's text aggregated. These
/// helpers keep the `sukiru.<surface>.<element>` token visible in that dump
/// WITHOUT hiding the human-readable string, verified empirically against
/// the live tree:
///
/// - `AXToken` — a zero-width-space Text carrying the token as its label. It
///   survives as its own AX element and prints `text <token>` right beside
///   the visible content. (Zero-size `Color.clear` carriers are dropped from
///   the tree; a zwsp Text is not.)
/// - `axButtonToken` — buttons flatten their content away and print only
///   `button, Value: <AXValue>`, so the token is set as BOTH label and value.
enum AXTokens {
    /// Skill names embedded in labels replace `.` with `-`.
    static func skill(_ name: String) -> String {
        name.replacingOccurrences(of: ".", with: "-")
    }

    /// Sanitizes a path or workspace id into one label segment (deterministic;
    /// anything not alphanumerics or `-` becomes `-`).
    static func path(_ raw: String) -> String {
        String(raw.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
    }
}

/// An invisible leaf element that exposes an accessibility token in the AX tree while
/// the visible sibling stays readable (see the note on `AXTokens`).
struct AXToken: View {
    let token: String

    var body: some View {
        Text(verbatim: "\u{200B}")
            .accessibilityLabel(token)
    }
}

/// A `Form` / `List` section header: the accessibility token carrier, the localized
/// title, and an optional trailing count (the count reads as a system-styled
/// secondary number, the way Finder and Mail label group sizes).
struct TokenSectionHeader: View {
    let token: String?
    let title: LocalizedStringKey
    var count: Int?

    var body: some View {
        HStack(spacing: 0) {
            if let token {
                AXToken(token: token)
            }
            Text(title)
            if let count {
                Spacer(minLength: 8)
                Text(count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// Applies an accessibility token to a button-style control: label for VoiceOver,
    /// value so the computer-use tree dump prints `button, Value: <token>`.
    /// Disabled state appends `.disabled`; pair with `.disabled(true)`
    /// so AX enabled=false.
    func axButtonToken(_ token: String, disabled: Bool = false) -> some View {
        let full = disabled ? token + ".disabled" : token
        return accessibilityLabel(full).accessibilityValue(full)
    }
}
