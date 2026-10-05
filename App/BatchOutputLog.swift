import Foundation
import SukiruCore

/// The live transcript of a running batch: each command line, then what the
/// command has printed so far, polled from the output files the executor
/// writes. Kept out of `AppState`'s published state so each refresh redraws
/// only the transcript.
@MainActor
final class BatchOutputLog: ObservableObject {
    @Published private(set) var text = ""

    private struct Entry {
        let header: String
        let files: [String]
        var offsets: [UInt64]
        var raw = Data()
    }

    private static let pollInterval: TimeInterval = 0.2
    private static let maxRawBytes = 256 * 1024
    private static let maxLines = 1000

    private var entries: [Entry] = []
    private var timer: Timer?

    func reset() {
        timer?.invalidate()
        timer = nil
        entries = []
        text = ""
    }

    func begin(_ command: CommandStart) {
        poll()
        entries.append(
            Entry(
                header: "$ " + command.displayString,
                files: [command.stdoutFile, command.stderrFile], offsets: [0, 0]))
        render()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // `.common` keeps the transcript updating while the user scrolls it.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// A `CLIExecutor` `onCommandStart` handler for the executing thread. The
    /// main queue is FIFO, so every start lands before the run's completion.
    nonisolated var onCommandStart: @Sendable (CommandStart) -> Void {
        { [weak self] command in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.begin(command) } }
        }
    }

    func finish() {
        timer?.invalidate()
        timer = nil
        poll()
    }

    /// Appends whatever the newest command wrote since the last poll; the
    /// earlier commands were read to the end when their successor began.
    private func poll() {
        guard var entry = entries.last else { return }
        var grew = false
        for (index, path) in entry.files.enumerated() {
            guard let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: entry.offsets[index])) != nil,
                let data = try? handle.readToEnd(), !data.isEmpty
            else { continue }
            entry.offsets[index] += UInt64(data.count)
            entry.raw.append(data)
            grew = true
        }
        guard grew else { return }
        if entry.raw.count > Self.maxRawBytes {
            let cut = entry.raw.index(entry.raw.endIndex, offsetBy: -Self.maxRawBytes)
            let start = entry.raw[cut...].firstIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? cut
            entry.raw = Data(entry.raw[start...])
        }
        entries[entries.count - 1] = entry
        render()
    }

    private func render() {
        let transcript = entries.map { entry in
            // A command mid-write can end inside a multi-byte character; lossy
            // decoding keeps everything before it visible.
            // swiftlint:disable:next optional_data_string_conversion
            var output = TerminalText.render(String(decoding: entry.raw, as: UTF8.self))
            while output.hasSuffix("\n") { output.removeLast() }
            return output.isEmpty ? entry.header : entry.header + "\n" + output
        }
        .joined(separator: "\n\n")
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false)
        text =
            lines.count > Self.maxLines
            ? lines.suffix(Self.maxLines).joined(separator: "\n") : transcript
    }
}
