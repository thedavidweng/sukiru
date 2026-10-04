import Foundation

/// Batch construction failed. `problems` names every offending decision
/// (unknown or stale finding IDs, inapplicable actions, missing choices) so
/// the caller can report them all at once.
public struct BatchBuildError: Error, Equatable, Sendable {
    public let problems: [String]

    public init(problems: [String]) {
        self.problems = problems
    }
}

/// How a skill's host-folder placements hold it.
public enum PlacementMode: String, Codable, Equatable, Sendable, CaseIterable {
    /// Links into the scope's shared skills folder.
    case link
    /// Standalone copies.
    case copy
}

/// A single inapplicable decision (aggregated into `BatchBuildError`).
struct DecisionProblem: Error, Equatable, Sendable {
    let message: String
}

/// Maps findings + user decisions to a CommandBatch.
///
/// Routing rules:
/// - vercel-ledger updates → `npx skills update <name> (-p|-g) -y`;
///   `vercel-lock-drift` findings re-install from the recorded source instead
///   (update never rewrites drifted copies).
/// - github-ledger updates → `gh skill update <name> --dir <dir>`.
/// - Routing NEVER crosses ledgers; ownerless skills are never silently
///   routed; ambiguous names route as ownerless.
/// - double-booked repairs REQUIRE an explicit surviving-ledger choice
///   (arbitrate + keep-vercel/keep-github) before any batch exists.
/// - every `npx skills remove` carries the dangerous-deletion flag and names
///   detectable at-risk cross-ledger skills.
/// - unknown or stale finding references are rejected here, at construction:
///   IDs are minted from the CURRENT report, so a stale file simply fails
///   to match.
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
    ///   every decision is `leave` (leave-as-is produces no batch).
    /// - Throws: `BatchBuildError` listing every problem found.
    public func build(
        report: ScanReport, decisions: [DecisionEntry]
    ) throws -> CommandBatch? {
        let planned = plan(report: report, decisions: decisions)
        guard planned.problems.isEmpty else {
            throw BatchBuildError(problems: planned.problems)
        }
        return batch(from: planned)
    }

    /// Builds one batch from every decision and Library request that
    /// applies, skipping the rest (Fix All: one inapplicable repair must not
    /// block the others).
    ///
    /// - Returns: the batch (nil when nothing applies) and the problem of
    ///   every skipped decision or request.
    public func buildApplicable(
        report: ScanReport, decisions: [DecisionEntry], lifecycle: [LifecycleRequest] = []
    ) -> (batch: CommandBatch?, skipped: [String]) {
        var planned = plan(report: report, decisions: decisions)
        planLifecycle(lifecycle, report: report, into: &planned)
        return (batch(from: planned), planned.problems)
    }

    /// Switches every placement of one skill to links into the shared
    /// skills folder or to standalone copies (Library mode switch). Not a
    /// finding fix, so like a new install it carries a synthetic finding
    /// ref for the snapshot and affected-scope derivation.
    public func buildModeSwitch(
        skill: Skill, to mode: PlacementMode, report: ScanReport
    ) throws -> CommandBatch {
        guard let bucket = Self.bucket(of: skill, report: report) else {
            throw BatchBuildError(problems: ["no scanned scope holds '\(skill.name)'"])
        }
        let commands: [BatchCommand]
        do {
            switch mode {
            case .link:
                commands = try Self.relinkPlan(
                    skill: skill, bucket: bucket, report: report, reason: "switch to links")
            case .copy:
                commands = try Self.materializePlan(skill: skill, bucket: bucket, report: report)
            }
        } catch let problem as DecisionProblem {
            throw BatchBuildError(problems: [problem.message])
        }
        let id = idProvider()
        return CommandBatch(
            id: id,
            createdAt: ISO8601DateFormatter().string(from: dateProvider()),
            findingRefs: [
                FindingRef(
                    findingID: id, ruleID: "placement-mode", skillName: skill.name,
                    workspaceID: bucket)
            ],
            decisions: [],
            commands: commands,
            snapshotID: nil,
            status: .proposed)
    }

    // MARK: - planning

    struct PlannedDecisions {
        var commands: [BatchCommand] = []
        var refs: [FindingRef] = []
        var records: [BatchDecision] = []
        var problems: [String] = []
    }

    func plan(report: ScanReport, decisions: [DecisionEntry]) -> PlannedDecisions {
        let findingsByID = Dictionary(
            uniqueKeysWithValues: FindingID.assignments(for: report.findings).map {
                ($0.id, $0.finding)
            })
        var planned = PlannedDecisions()
        for entry in decisions.sorted(by: { $0.findingID < $1.findingID }) {
            guard let finding = findingsByID[entry.findingID] else {
                planned.problems.append(
                    "unknown or stale finding ID '\(entry.findingID)': no such finding "
                        + "in the current scan")
                continue
            }
            do {
                // Several findings can name one repair (a skill's duplicate
                // and impostor findings both relink the same copy); each
                // command runs once.
                for command in try plan(entry: entry, finding: finding, report: report)
                where !planned.commands.contains(where: { $0.argv == command.argv }) {
                    planned.commands.append(command)
                }
            } catch {
                planned.problems.append((error as? DecisionProblem)?.message ?? "\(error)")
                continue
            }
            // Refs carry the ownership bucket: snapshot, bounds, and rescan
            // derive from it, and a dead link's finding names its host
            // workspace.
            planned.refs.append(
                FindingRef(
                    findingID: entry.findingID,
                    ruleID: finding.ruleID,
                    skillName: finding.skillName,
                    workspaceID: Self.bucket(of: finding.workspaceID)))
            planned.records.append(
                BatchDecision(
                    findingID: entry.findingID, action: entry.action, choice: entry.choice))
        }
        return planned
    }

    private func batch(from planned: PlannedDecisions) -> CommandBatch? {
        guard !planned.commands.isEmpty else {
            return nil
        }
        return CommandBatch(
            id: idProvider(),
            createdAt: ISO8601DateFormatter().string(from: dateProvider()),
            findingRefs: planned.refs,
            decisions: planned.records,
            commands: planned.commands,
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
        case .arbitrate where finding.ruleID == HostNameCollisionRule.ruleID:
            return try keepEntryCommands(entry: entry, finding: finding, report: report)
        case .arbitrate:
            return try arbitrateCommands(entry: entry, finding: finding, report: report)
        case .adopt:
            return try adoptCommands(entry: entry, finding: finding, report: report)
        case .relink:
            try requireNoChoice(entry: entry)
            return try relinkCommands(entry: entry, finding: finding, report: report)
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
