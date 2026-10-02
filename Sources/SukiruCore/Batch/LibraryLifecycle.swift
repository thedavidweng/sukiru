import Foundation

/// A change the user asks for on a ledger-owned skill from the Library,
/// rather than as the repair of a finding.
public enum LifecycleAction: String, Codable, Equatable, Sendable, CaseIterable {
    case update
    case uninstall
    /// Set a pinned version (GitHub ledger only; `pinRef` carries the ref).
    case pin
    /// Clear the pinned version (GitHub ledger only).
    case unpin
    /// Re-download the recorded version over local edits (GitHub ledger
    /// only).
    case restore

    /// The synthetic finding-ref rule ID (like `new-install`): the executor's
    /// snapshot, bounds, and rescan derive their scope from finding refs.
    public var ruleID: String { "library-\(rawValue)" }
}

/// One queued Library change: the skill as the current scan reports it.
public struct LifecycleRequest: Identifiable, Equatable, Sendable {
    public let skill: Skill
    public let action: LifecycleAction
    /// The ref a `pin` request installs at; nil for every other action.
    public let pinRef: String?

    public init(skill: Skill, action: LifecycleAction, pinRef: String? = nil) {
        self.skill = skill
        self.action = action
        self.pinRef = action == .pin ? pinRef : nil
    }

    /// Also the synthetic finding ID of the batch ref the request produces,
    /// so a caller can tell which requests an executed batch carried.
    public var id: String {
        var parts = [
            action.ruleID, skill.scope.rawValue, skill.name, skill.placements.first?.path ?? "-"
        ]
        if let pinRef {
            parts.append(pinRef)
        }
        return parts.joined(separator: "|")
    }

    /// A usable git ref for pinning: non-empty, no whitespace or control
    /// characters (git refs never contain either; gh accepts tags, branch
    /// names, and commit SHAs).
    public static func isValidPinRef(_ ref: String) -> Bool {
        !ref.isEmpty && ref.allSatisfy { !$0.isWhitespace }
            && ref.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

/// Why the Library cannot offer an action for a skill.
public enum LifecycleBlocker: Equatable, Sendable {
    /// Both ledgers claim the skill: a surviving ledger must be chosen first.
    case doubleBooked
    /// Distinct copies disagree, so ownership attribution is voided.
    case ambiguous
    /// A host manages the skill through its own records.
    case agentManaged
    /// No ledger records the skill (Library offers deletion or adoption).
    case ownerless
    /// The owning ledger's CLI is `npx skills`, and npx is missing.
    case needsNpx
    /// The owning ledger's CLI is `gh skill`, and gh is unavailable.
    case needsGitHubCLI
    /// gh would overwrite the Vercel ledger's user-scope record of this name
    /// (see `CommandBatchBuilder.githubWriteBlocker`).
    case touchesVercelRecord
    /// gh's rewrite of the Vercel global lock would drop data npx needs from
    /// other records (see `CommandBatchBuilder.githubWriteBlocker`).
    case dropsVercelLockData
    /// Pin, unpin, and restore exist only in the GitHub ledger; the Vercel
    /// ledger has no pin or re-download concept.
    case githubLedgerOnly
    /// The skill is already pinned (Pin applies to unpinned skills).
    case alreadyPinned
    /// The skill is not pinned (Unpin applies to pinned skills).
    case notPinned

    /// Human-readable refusal (English by design, like other core refusals).
    var message: String {
        switch self {
        case .doubleBooked:
            return "both ledgers claim this skill; choose a surviving ledger in Health first"
        case .ambiguous:
            return "ownership is ambiguous, so no ledger may act on this skill"
        case .agentManaged:
            return "an agent manages this skill through its own records"
        case .ownerless:
            return "no ledger owns this skill"
        case .needsNpx:
            return "the Vercel ledger's CLI (npx skills) is not available"
        case .needsGitHubCLI:
            return "the GitHub ledger's CLI (gh skill) is not available"
        case .touchesVercelRecord:
            return "gh skill also records the skill under its name in the Vercel ledger's "
                + "global lock, which would overwrite the Vercel record of the user-scope "
                + "skill of this name"
        case .dropsVercelLockData:
            return "gh skill rewrites the Vercel ledger's global lock and would drop data "
                + "npx skills needs from other records (the branch or tag a skill was "
                + "installed from, a well-known source, or fields gh does not know)"
        case .githubLedgerOnly:
            return "only the GitHub ledger (gh skill) supports this action; the Vercel "
                + "ledger has no pin or re-download concept"
        case .alreadyPinned:
            return "the skill is already pinned; unpin it first to change the pin"
        case .notPinned:
            return "the skill is not pinned"
        }
    }

    /// The refusal for `action` on `skill`, as the batch builder phrases it.
    public func refusal(_ action: LifecycleAction, skill: Skill) -> String {
        "cannot \(action.rawValue) '\(skill.name)': \(message)"
    }
}

extension CommandBatchBuilder {
    /// Whether the Library can queue `action` for `skill`. Capabilities not
    /// yet probed (nil) block nothing, as with one-click fixes; without a
    /// report, the cross-scope Vercel record check is skipped. A GitHub
    /// uninstall deletes files directly, so it needs no `gh`. Pin, unpin,
    /// and restore are GitHub-ledger writes, so they carry the same
    /// capability and `githubWriteBlocker` guards as a gh update, plus their
    /// pin-state preconditions.
    public static func lifecycleBlocker(
        skill: Skill, action: LifecycleAction, capabilities: CapabilityReport?,
        report: ScanReport? = nil
    ) -> LifecycleBlocker? {
        if skill.ambiguous {
            return .ambiguous
        }
        switch skill.ownership {
        case .doubleBooked:
            return .doubleBooked
        case .agent:
            return .agentManaged
        case .ownerless:
            return .ownerless
        case .vercel:
            guard action == .update || action == .uninstall else {
                return .githubLedgerOnly
            }
            return capabilities?.npx.canRunSkills == false ? .needsNpx : nil
        case .github:
            return githubLifecycleBlocker(
                skill: skill, action: action, capabilities: capabilities, report: report)
        }
    }

    /// The GitHub-ledger branch of `lifecycleBlocker`: uninstall is a direct
    /// deletion needing no `gh`; every other action is a gh write, so it
    /// carries the capability and `githubWriteBlocker` guards plus the
    /// pin-state preconditions.
    private static func githubLifecycleBlocker(
        skill: Skill, action: LifecycleAction, capabilities: CapabilityReport?,
        report: ScanReport?
    ) -> LifecycleBlocker? {
        guard action != .uninstall else { return nil }
        if capabilities?.github.available == false {
            return .needsGitHubCLI
        }
        if action == .pin, skill.provenance.github?.pinned == true {
            return .alreadyPinned
        }
        if action == .unpin, skill.provenance.github?.pinned != true {
            return .notPinned
        }
        return report.flatMap { githubWriteBlocker(skillName: skill.name, report: $0) }
    }

    /// Why a `gh skill` install or update of `name` must not run. Every one
    /// also writes `~/.agents/.skill-lock.json`, the Vercel ledger's global
    /// lock (`lockfile.RecordInstall` since gh 2.90.0; probe-verified in
    /// docs/collision-matrix.md): it records `name` there whatever the scope
    /// or `--dir`, and rewrites the whole file through a struct that keeps
    /// only gh's own fields, or replaces it when the version is not 3.
    ///
    /// - `.touchesVercelRecord`: a user-scope skill of this name has a Vercel
    ///   record that is not gh's companion record of a GitHub-ledger skill.
    ///   `replacing` is a skill whose record the batch removes first
    ///   (keep-GitHub arbitration).
    /// - `.dropsVercelLockData`: a Vercel record carries a `ref`, a well-known
    ///   source, or keys gh does not know, the lock has unknown top-level
    ///   keys, or it is newer than version 3. gh also drops plugin groups and
    ///   the last selected agents, which only shape npx's display; the
    ///   command's consequence discloses that instead.
    ///
    /// A fileless record (`lock-without-files`) describes nothing on disk,
    /// so gh overwriting it is not guarded.
    public static func githubWriteBlocker(
        skillName name: String, report: ScanReport, replacing: Skill? = nil
    ) -> LifecycleBlocker? {
        let userRecords = report.skills.filter { $0.scope == .user && $0.provenance.vercel != nil }
        if userRecords.contains(where: {
            $0.name == name && $0.ownership != .github && $0 != replacing
        }) {
            return .touchesVercelRecord
        }
        let lockIsNewer = report.findings.contains {
            $0.ruleID == "lock-version-unsupported" && $0.workspaceID == "user"
        }
        let unknownTopLevelKeys = report.lockExtras?["user"]?.isEmpty == false
        let recordLoses = userRecords.contains { skill in
            guard let record = skill.provenance.vercel, record.githubCompanion != true,
                skill != replacing
            else { return false }
            let extraKeys = (record.extras ?? [:]).keys.filter { $0 != "pinnedRef" }
            return record.ref != nil || record.sourceType == "well-known" || !extraKeys.isEmpty
        }
        return lockIsNewer || unknownTopLevelKeys || recordLoses ? .dropsVercelLockData : nil
    }

    /// A Health update of a GitHub-ledger skill: one `gh skill update` per
    /// skills dir, under the same Vercel-record guard as the Library.
    func githubUpdateCommands(
        _ skill: Skill, entry: DecisionEntry, finding: Finding, report: ScanReport
    ) throws -> [BatchCommand] {
        let dirs = placementDirs(skill)
        guard !dirs.isEmpty else {
            throw noDirectoryPlacements(skill: skill, entry: entry)
        }
        if let blocker = Self.githubWriteBlocker(skillName: skill.name, report: report) {
            throw DecisionProblem(message: blocker.refusal(.update, skill: skill))
        }
        return dirs.map { dir in
            BatchCommandFactory.githubUpdate(
                names: [skill.name], dir: dir, reason: "finding \(finding.ruleID)")
        }
    }

    /// Deletes every placement of a GitHub-ledger skill: links (live or
    /// dead) as links, never following them, then the directories.
    static func githubUninstall(
        _ skill: Skill, reason: String = "requested in the Library"
    ) -> [BatchCommand] {
        let intent =
            "Uninstall '\(skill.name)' (\(reason)): gh skill has no "
            + "uninstall command, so its placements are deleted directly."
        let placements = skill.placements.sorted { $0.path < $1.path }
        let links = placements.filter { $0.kind != .directory }.map {
            BatchCommandFactory.deleteLink(name: skill.name, path: $0.path, intent: intent)
        }
        let dirs = placements.filter { $0.kind == .directory }.map {
            BatchCommandFactory.deleteGitHubSkillDirectory(
                name: skill.name, path: $0.path, intent: intent)
        }
        return links + dirs
    }

    static func projectRoot(ofBucket bucket: String) -> String? {
        bucket.hasPrefix("project:") ? String(bucket.dropFirst("project:".count)) : nil
    }
}
