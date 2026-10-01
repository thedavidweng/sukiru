import Foundation

/// Stable, deterministic identifiers for findings — the keys of the
/// decisions file.
///
/// The base ID is `<ruleID>:<workspaceID>:<skillName or "-">`. When several
/// findings share one base (e.g. per-placement drift findings), repeats are
/// suffixed `#2`, `#3`, … in the report's defined sorted order. IDs are never
/// parsed back; they are minted from a scan and compared by equality, which
/// is exactly what makes stale references rejectable at batch construction:
/// an ID minted from an older scan no longer appears in a
/// fresh one.
public enum FindingID {
    /// Assigns IDs to every finding, in the report's deterministic order.
    public static func assignments(for findings: [Finding]) -> [(id: String, finding: Finding)] {
        var counts: [String: Int] = [:]
        return findings.sorted(by: order).map { finding in
            let base = baseID(for: finding)
            let seen = (counts[base] ?? 0) + 1
            counts[base] = seen
            return (seen == 1 ? base : base + "#\(seen)", finding)
        }
    }

    /// The base identifier for one finding (no repeat suffix).
    public static func baseID(for finding: Finding) -> String {
        finding.ruleID + ":" + finding.workspaceID + ":" + (finding.skillName ?? "-")
    }

    /// The ScanEngine finding order: rule, workspace, skill, then evidence
    /// content as the final tiebreak. Mirrored here so ID assignment is
    /// stable even if the input array is not pre-sorted.
    private static func order(_ lhs: Finding, _ rhs: Finding) -> Bool {
        let lhsKey = (lhs.ruleID, lhs.workspaceID, lhs.skillName ?? "")
        let rhsKey = (rhs.ruleID, rhs.workspaceID, rhs.skillName ?? "")
        if lhsKey != rhsKey {
            return lhsKey < rhsKey
        }
        let lhsEvidence = lhs.evidence.map { $0.kind + "\u{1F}" + $0.detail }
        let rhsEvidence = rhs.evidence.map { $0.kind + "\u{1F}" + $0.detail }
        return lhsEvidence.lexicographicallyPrecedes(rhsEvidence)
    }
}
