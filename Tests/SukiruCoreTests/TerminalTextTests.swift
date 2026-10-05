import Testing

@testable import SukiruCore

/// Escape sequences recorded from real `npx skills` runs, rendered the way a
/// terminal would show them.
@Suite("Terminal text")
struct TerminalTextTests {
    @Test("Plain lines pass through unchanged")
    func plainText() {
        #expect(
            TerminalText.render("Updating demo…\n  ✓ Updated demo\n")
                == "Updating demo…\n  ✓ Updated demo\n")
    }

    @Test("Color, style, and cursor-visibility sequences are dropped")
    func stylesDropped() {
        let raw =
            "\u{1B}[?25l\u{1B}[38;5;145mUpdating\u{1B}[0m \u{1B}[2mdemo\u{1B}[22m\n\u{1B}[?25h"
        #expect(TerminalText.render(raw) == "Updating demo\n")
    }

    @Test("A spinner redrawn with ESC[1G ESC[J keeps only its last frame")
    func spinnerRedraw() {
        let raw =
            "◒  Cloning repository\u{1B}[1G\u{1B}[J◐  Cloning repository.\u{1B}[1G\u{1B}[J"
            + "◇  Repository cloned\n"
        #expect(TerminalText.render(raw) == "◇  Repository cloned\n")
    }

    @Test("A carriage return with ESC[K replaces the line; CRLF ends it")
    func carriageReturn() {
        let raw = "\rChecking a\u{1B}[K\rChecking b\u{1B}[K\r\n" + "done\r\n"
        #expect(TerminalText.render(raw) == "Checking b\ndone\n")
    }

    @Test("A frame still being drawn stays visible until it is replaced")
    func liveFrame() {
        #expect(TerminalText.render("◒  Cloning\u{1B}[1G") == "◒  Cloning")
        #expect(TerminalText.render("◒  Cloning\r\u{1B}[K") == "")
    }

    @Test("OSC hyperlinks keep their text; stray controls are dropped")
    func oscAndControls() {
        let raw = "\u{1B}]8;;https://skills.sh\u{7}skills.sh\u{1B}]8;;\u{1B}\\ ok\u{7}\tx\n"
        #expect(TerminalText.render(raw) == "skills.sh ok\tx\n")
    }
}
