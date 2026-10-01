import Foundation

/// The Command Batch model.
///
/// A batch maps findings + user decisions to an ordered list of commands.
/// Ledger writes are ONLY official CLI invocations (`npx skills …`,
/// `gh skill …`); direct file operations never touch a ledger and are limited
/// to ownerless payloads, host-folder placements (dead links, link ↔ copy
/// mode), and leftover host folders, always flagged as such (ADR-0007).

/// Repair actions in the decisions-file vocabulary.
public enum DecisionAction: String, Codable, Equatable, Sendable, CaseIterable {
    case update
    case adopt
    case cleanup
    case leave
    case arbitrate
    /// Replace host-folder copies with links into the shared skills store.
    case relink
}

/// The explicit user choice accompanying an action.
///
/// Arbitration choices encode as the strings `"keep-vercel"` / `"keep-github"`;
/// GitHub adoption carries the user-supplied source as
/// `{"repo": "owner/repo", "path": "repo-relative/skill/path"}`; Vercel
/// adoption carries `{"source": "owner/repo"}` (the skill keeps its name).
public enum DecisionChoice: Equatable, Sendable {
    case keepVercel
    case keepGitHub
    case adoptSource(repo: String, path: String)
    case adoptVercel(source: String)
}

extension DecisionChoice: Codable {
    private enum CodingKeys: String, CodingKey {
        case repo
        case path
        case source
    }

    public init(from decoder: Decoder) throws {
        if let string = try? decoder.singleValueContainer().decode(String.self) {
            switch string {
            case "keep-vercel":
                self = .keepVercel
            case "keep-github":
                self = .keepGitHub
            default:
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "unknown arbitration choice '\(string)'")
            }
            return
        }
        let object = try decoder.container(keyedBy: CodingKeys.self)
        if let source = try object.decodeIfPresent(String.self, forKey: .source) {
            self = .adoptVercel(source: source)
            return
        }
        self = .adoptSource(
            repo: try object.decode(String.self, forKey: .repo),
            path: try object.decode(String.self, forKey: .path))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .keepVercel:
            var container = encoder.singleValueContainer()
            try container.encode("keep-vercel")
        case .keepGitHub:
            var container = encoder.singleValueContainer()
            try container.encode("keep-github")
        case .adoptSource(let repo, let path):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(repo, forKey: .repo)
            try container.encode(path, forKey: .path)
        case .adoptVercel(let source):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(source, forKey: .source)
        }
    }
}

/// Which official CLI a batch command belongs to.
///
/// `.file` marks the non-CLI command class: a direct file operation that
/// writes no ledger (always danger-flagged, ADR-0007).
public enum OwningCLI: String, Codable, Equatable, Sendable {
    case vercel
    case github
    case file
}

/// Danger flags carried on batch commands.
public enum DangerFlag: String, Codable, Equatable, Sendable {
    /// `npx skills remove` deletes by name across ownership
    /// (collision-matrix scenario 6) — every remove carries this flag.
    case dangerousDeletion = "dangerous-deletion"
    /// The command mutates files directly instead of through an official CLI.
    case directFileOperation = "direct-file-operation"
    /// The direct file operation targets an ownerless skill's payload.
    case ownerlessCleanup = "ownerless-cleanup"
    /// The direct file operation replaces content that differs from what
    /// replaces it (a diverged host copy relinked to the shared store).
    case discardsLocalChanges = "discards-local-changes"
}

/// A skill endangered by a name-based `npx skills remove`, with the ledger
/// that owns it.
public struct AtRiskSkill: Codable, Equatable, Sendable {
    public let skill: String
    public let ownership: String

    public init(skill: String, ownership: String) {
        self.skill = skill
        self.ownership = ownership
    }
}

/// One command in a batch.
public struct BatchCommand: Codable, Equatable, Sendable {
    /// The complete argument vector, nothing elided.
    public let argv: [String]
    /// Human-readable rendering of the same invocation.
    public let displayString: String
    public let owningCLI: OwningCLI
    /// Non-empty rationale referencing the finding the command addresses.
    public let intent: String
    public let dangerFlags: [DangerFlag]
    /// Danger prose, present whenever `dangerFlags` is non-empty.
    public let warning: String?
    /// Cross-ledger skills endangered by a name-based removal, when
    /// detectable from the scan.
    public let atRiskSkills: [AtRiskSkill]
    /// Consequence text for destructive-by-design commands:
    /// the English rendering of `consequenceKind`.
    public let consequence: String?
    /// The structured consequence, for presentation layers that localize.
    public let consequenceKind: CommandConsequence?
    /// The working directory the command must run in: the project root for
    /// project-scope `npx` commands (the CLI resolves `-p` literally from
    /// cwd — research/cli-surface-npx.md); nil elsewhere.
    public let workingDirectory: String?

    public init(
        argv: [String],
        displayString: String,
        owningCLI: OwningCLI,
        intent: String,
        dangerFlags: [DangerFlag],
        warning: String?,
        atRiskSkills: [AtRiskSkill] = [],
        consequence: CommandConsequence? = nil,
        workingDirectory: String? = nil
    ) {
        self.argv = argv
        self.displayString = displayString
        self.owningCLI = owningCLI
        self.intent = intent
        self.dangerFlags = dangerFlags
        self.warning = warning
        self.atRiskSkills = atRiskSkills
        self.consequence = consequence?.text
        self.consequenceKind = consequence
        self.workingDirectory = workingDirectory
    }

    /// The direct file operation this command performs, if it is one.
    public var fileOperation: FileOperation? {
        FileOperation(argv: argv)
    }

    /// Shell-style rendering of an argv: arguments containing anything
    /// outside a conservative safe set are single-quoted.
    public static func display(for argv: [String]) -> String {
        argv.map(shellQuoted).joined(separator: " ")
    }

    private static func shellQuoted(_ argument: String) -> String {
        let safe = !argument.isEmpty && argument.allSatisfy(isSafeCharacter)
        if safe {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isSafeCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "_./:=@+-".contains(character)
    }
}

/// A batch's reference to the finding that motivated a decision:
/// the finding ID plus the wire fields it round-trips to.
public struct FindingRef: Codable, Equatable, Sendable {
    public let findingID: String
    public let ruleID: String
    public let skillName: String?
    public let workspaceID: String

    public init(findingID: String, ruleID: String, skillName: String?, workspaceID: String) {
        self.findingID = findingID
        self.ruleID = ruleID
        self.skillName = skillName
        self.workspaceID = workspaceID
    }
}

/// The user decision record that produced part of a batch.
public struct BatchDecision: Codable, Equatable, Sendable {
    public let findingID: String
    public let action: DecisionAction
    public let choice: DecisionChoice?

    public init(findingID: String, action: DecisionAction, choice: DecisionChoice?) {
        self.findingID = findingID
        self.action = action
        self.choice = choice
    }
}

/// Batch lifecycle states. Terminal states are terminal.
public enum BatchStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case proposed
    case reviewed
    case executing
    case succeeded
    case failed
    case rolledBack

}

/// A refused lifecycle transition.
public enum BatchTransitionError: Error, Equatable, Sendable {
    case illegalTransition(from: BatchStatus, target: BatchStatus)

    /// Human-readable refusal naming both states.
    public var message: String {
        switch self {
        case .illegalTransition(let from, let target):
            return "illegal batch transition: '\(from.rawValue)' cannot transition to "
                + "'\(target.rawValue)'"
        }
    }
}

/// A reviewable command batch.
///
/// `snapshotID` is always present in the wire JSON — explicitly `null` until
/// execution commits the snapshot — so the type carries a
/// custom encoder instead of the synthesized omit-when-nil behavior.
public struct CommandBatch: Equatable, Sendable {
    public let id: String
    /// ISO-8601 creation timestamp.
    public let createdAt: String
    public let findingRefs: [FindingRef]
    public let decisions: [BatchDecision]
    public let commands: [BatchCommand]
    public let snapshotID: String?
    public let status: BatchStatus

    public init(
        id: String,
        createdAt: String,
        findingRefs: [FindingRef],
        decisions: [BatchDecision],
        commands: [BatchCommand],
        snapshotID: String?,
        status: BatchStatus
    ) {
        self.id = id
        self.createdAt = createdAt
        self.findingRefs = findingRefs
        self.decisions = decisions
        self.commands = commands
        self.snapshotID = snapshotID
        self.status = status
    }

    /// Whether the lifecycle permits `status → target`.
    public static func allowsTransition(from status: BatchStatus, to target: BatchStatus) -> Bool {
        switch (status, target) {
        case (.proposed, .reviewed),
            (.reviewed, .executing),
            (.executing, .succeeded),
            (.executing, .failed),
            (.succeeded, .rolledBack),
            (.failed, .rolledBack):
            return true
        default:
            return false
        }
    }

    /// Returns the batch in a new status, or throws when the transition is
    /// illegal (terminal states are terminal; no rollback mid-execution).
    public func transitioned(to target: BatchStatus) throws -> CommandBatch {
        guard Self.allowsTransition(from: status, to: target) else {
            throw BatchTransitionError.illegalTransition(from: status, target: target)
        }
        return CommandBatch(
            id: id,
            createdAt: createdAt,
            findingRefs: findingRefs,
            decisions: decisions,
            commands: commands,
            snapshotID: snapshotID,
            status: target
        )
    }

    /// Deterministic JSON encoding (sorted keys) like the scan report.
    public func jsonData() throws -> Data {
        try deterministicJSONData(self)
    }
}

extension CommandBatch: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case findingRefs
        case decisions
        case commands
        case snapshotID
        case status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            createdAt: try container.decode(String.self, forKey: .createdAt),
            findingRefs: try container.decode([FindingRef].self, forKey: .findingRefs),
            decisions: try container.decode([BatchDecision].self, forKey: .decisions),
            commands: try container.decode([BatchCommand].self, forKey: .commands),
            snapshotID: try container.decodeIfPresent(String.self, forKey: .snapshotID),
            status: try container.decode(BatchStatus.self, forKey: .status)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(findingRefs, forKey: .findingRefs)
        try container.encode(decisions, forKey: .decisions)
        try container.encode(commands, forKey: .commands)
        // Explicit null when nil, never an omitted key.
        try container.encode(snapshotID, forKey: .snapshotID)
        try container.encode(status, forKey: .status)
    }
}
