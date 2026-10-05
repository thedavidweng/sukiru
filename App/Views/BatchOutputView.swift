import SwiftUI

/// The running batch's commands and their live output, read-only and
/// selectable like terminal scrollback, kept scrolled to the newest line.
struct BatchOutputView: View {
    @ObservedObject var log: BatchOutputLog

    var body: some View {
        GroupBox {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(verbatim: log.text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(Self.transcriptID)
                }
                .onChange(of: log.text) {
                    proxy.scrollTo(Self.transcriptID, anchor: .bottom)
                }
            }
            .frame(height: 240)
        }
        .accessibilityLabel("Command output")
        .accessibilityIdentifier("sukiru.confirm.output")
        .help("Live output of the commands being applied")
    }

    private static let transcriptID = "transcript"
}
