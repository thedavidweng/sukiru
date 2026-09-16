import Foundation

/// Batch construction failed. `problems` names every offending decision
/// (unknown or stale finding IDs, inapplicable actions, missing choices) so
/// the caller can report them all at once (VAL-REPAIR-052/056).
public struct BatchBuildError: Error, Equatable, Sendable {
    public let problems: [String]

    public init(problems: [String]) {
        self.problems = problems
    }
}

/// A single inapplicable decision (aggregated into `BatchBuildError`).
struct DecisionProblem: Error, Equatable, Sendable {
    let message: String
}

/// Maps findings + user decisions to a CommandBatch (architecture §4.1 repair
/// side, §7; decisions D8–D14, D22).
///
/// Routing rules:
/// - vercel-ledger updates → `npx skills update <name> (-p|-g) -y`;
///   `vercel-lock-drift` findings re-install from the recorded source instead
///   (D22 — update never rewrites drifted copies).
/// - github-ledger updates → `gh skill update <name> --dir <dir>` (D13).
/// - Routing NEVER crosses ledgers; ownerless skills are never silently
///   routed (VAL-REPAIR-011/012); ambiguous names route as ownerless
///   (VAL-REPAIR-057).
/// - double-booked repairs REQUIRE an explicit surviving-ledger choice
///   (arbitrate + keep-vercel/keep-github, D10) before any batch exists.
/// - every `npx skills remove` carries the dangerous-deletion flag and names
///   detectable at-risk cross-ledger skills (VAL-REPAIR-020/021).
/// - unknown or stale finding references are rejected here, at construction
///   (VAL-REPAIR-056): IDs are minted from the CURRENT report, so a stale
///   file simply fails to match.
///
/// The builder is pure: it consumes a ScanReport and never touches disk. The
/// per-action planners live in BatchPlanner.swift.
public struct CommandBatchBuilder: Sendable {
    private let idProvider: @Sendable () -> String
    private let dateProvider: @Sendable () -> Date

    public init(
        idProvider: @escaping @Sendable () -> String = { UUID().uuidString },
        dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.idProvider = idProvider
        self.dateProvider = dateProvider
    }

    /// Builds one batch from the decisions against the CURRENT report.
    ///
    /// - Returns: the batch (status `proposed`, no snapshot), or nil when
    ///   every decision is `leave` (leave-as-is produces no batch,
    ///   VAL-REPAIR-019).
    /// - Throws: `BatchBuildError` listing every problem found.
    public func build(
        report: ScanReport, decisions: [DecisionEntry]
    ) throws -> CommandBatch? {
        let findingsByID = Dictionary(
            uniqueKeysWithValues: FindingID.assignments(for: report.findings).map {
                ($0.id, $0.finding)
            })
        var problems: [String] = []
        var commands: [BatchCommand] = []
        var refs: [FindingRef] = []
        var records: [BatchDecision] = []
        for entry in decisions.sorted(by: { $0.findingID < $1.findingID }) {
            guard let finding = findingsByID[entry.findingID] else {
                problems.append(
                    "unknown or stale finding ID '\(entry.findingID)': no such finding "
                        + "in the current scan")
                continue
            }
            do {
                commands += try plan(entry: entry, finding: finding, report: report)
            } catch let problem as DecisionProblem {
                problems.append(problem.message)
                continue
            }
            refs.append(
                FindingRef(
                    findingID: entry.findingID,
                    ruleID: finding.ruleID,
                    skillName: finding.skillName,
                    workspaceID: finding.workspaceID))
            records.append(
                BatchDecision(
                    findingID: entry.findingID, action: entry.action, choice: entry.choice))
        }
        guard problems.isEmpty else {
            throw BatchBuildError(problems: problems)
        }
        guard !commands.isEmpty else {
            return nil
        }
        return CommandBatch(
            id: idProvider(),
            createdAt: ISO8601DateFormatter().string(from: dateProvider()),
            findingRefs: refs,
            decisions: records,
            commands: commands,
            snapshotID: nil,
            status: .proposed
        )
    }

    // MARK: - dispatch

    func plan(
        entry: DecisionEntry, finding: Finding, report: ScanReport
    ) throws -> [BatchCommand] {
        switch entry.action {
        case .leave:
            try requireNoChoice(entry: entry)
            return []
        case .update:
            try requireNoChoice(entry: entry)
            return try updateCommands(entry: entry, finding: finding, report: report)
        case .cleanup:
            try requireNoChoice(entry: entry)
            return try cleanupCommands(entry: entry, finding: finding, report: report)
        case .arbitrate:
            return try arbitrateCommands(entry: entry, finding: finding, report: report)
        case .adopt:
            return try adoptCommands(entry: entry, finding: finding, report: report)
        }
    }

    func requireNoChoice(entry: DecisionEntry) throws {
        if entry.choice != nil {
            throw DecisionProblem(
                message: "action '\(entry.action.rawValue)' on finding '\(entry.findingID)' "
                    + "takes no choice")
        }
    }
}
