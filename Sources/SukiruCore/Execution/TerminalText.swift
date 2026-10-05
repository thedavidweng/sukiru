/// Renders captured CLI output the way a terminal would show it, for the
/// subset that non-interactive CLIs emit. A carriage return or `ESC[G`
/// moves back to the start of the line, so the next text replaces it (a
/// spinner redraw); `ESC[K`, `ESC[2K`, and `ESC[J` erase it. Every other
/// escape sequence and control character except tab is dropped.
public enum TerminalText {
    public static func render(_ raw: String) -> String {
        let scalars = Array(raw.unicodeScalars)
        var state = State()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            switch scalar {
            case "\n":
                state.text.append(contentsOf: state.line)
                state.text.append("\n")
                state.line = String.UnicodeScalarView()
                state.returned = false
            case "\r":
                state.returned = true
            case "\u{8}":
                if !state.line.isEmpty { state.line.removeLast() }
            case "\u{1B}":
                index = escape(scalars, from: index, state: &state)
            default:
                guard scalar == "\t" || (scalar.value >= 0x20 && scalar.value != 0x7F) else {
                    continue
                }
                if state.returned {
                    state.line = String.UnicodeScalarView()
                    state.returned = false
                }
                state.line.append(scalar)
            }
        }
        state.text.append(contentsOf: state.line)
        return String(state.text)
    }

    private struct State {
        var text = String.UnicodeScalarView()
        var line = String.UnicodeScalarView()
        /// The cursor is back at column 1: the next printed text replaces the line.
        var returned = false
    }

    /// Consumes the sequence after an ESC at `start`, applying the line
    /// edits it encodes, and returns the index just past it.
    private static func escape(
        _ scalars: [Unicode.Scalar], from start: Int, state: inout State
    ) -> Int {
        guard start < scalars.count else { return start }
        switch scalars[start] {
        case "[":
            var index = start + 1
            var parameters = ""
            while index < scalars.count, (0x20...0x3F).contains(scalars[index].value) {
                parameters.unicodeScalars.append(scalars[index])
                index += 1
            }
            guard index < scalars.count else { return index }
            apply(final: scalars[index], parameters: parameters, state: &state)
            return index + 1
        case "]":
            // OSC (titles, hyperlinks): skip to BEL or ESC \.
            var index = start + 1
            while index < scalars.count {
                if scalars[index] == "\u{7}" { return index + 1 }
                if scalars[index] == "\u{1B}" { return min(index + 2, scalars.count) }
                index += 1
            }
            return index
        default:
            return start + 1
        }
    }

    private static func apply(final: Unicode.Scalar, parameters: String, state: inout State) {
        switch final {
        case "G" where parameters.isEmpty || parameters == "1":
            state.returned = true
        case "K" where parameters == "2":
            state.line = String.UnicodeScalarView()
        case "K", "J":
            if state.returned { state.line = String.UnicodeScalarView() }
        default:
            break
        }
    }
}
