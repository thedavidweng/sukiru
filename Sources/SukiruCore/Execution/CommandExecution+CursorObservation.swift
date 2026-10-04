import Foundation

extension CommandExecution {
    /// Exit status and observed local content are independent facts. Changes in a
    /// multi-command batch cannot be attributed to a particular refresh command.
    func observingCursorRefresh(diff: BatchDiff) -> CommandExecution {
        guard owningCLI == .cursor,
            Array(argv.prefix(4)) == ["agent", "plugin", "marketplace", "update"],
            status == .succeeded
        else { return self }
        let changed = diff.entries.contains {
            $0.path.contains("/.cursor/plugins/marketplaces/")
                || $0.path.contains("/.cursor/plugins/cache/")
        }
        let observation =
            changed
            ? "Observed local catalog/payload changes in this batch. "
                + "Backend indexing and runtime loading remain unverified."
            : "No observable local catalog/payload change in this batch despite exit code 0. "
                + "Backend indexing and runtime loading remain unverified; inspect the saved transcript."
        return CommandExecution(
            index: index, argv: argv, displayString: displayString, owningCLI: owningCLI,
            intent: intent, status: status, exitCode: exitCode, failureKind: failureKind,
            diagnostics: observation, stdoutFile: stdoutFile, stderrFile: stderrFile,
            startedAt: startedAt, endedAt: endedAt, durationSeconds: durationSeconds)
    }
}
