/// One logical skill name within one ownership bucket, before ownership
/// resolution (architecture D1; port-reference §4 alias collapse).
///
/// Grouping key is `(scopeGroup, name)`: one logical skill per skill name per
/// ownership bucket (`user` scope, or one bucket per project root — ownership
/// never leaks across scopes). Alias placements (several placements resolving
/// to ONE canonical path, e.g. host symlinks into the canonical store) are
/// one logical skill with N placements and are never ambiguous by themselves.
///
/// A group is `ambiguous` iff its name maps to MORE THAN ONE distinct
/// physical directory (distinct non-nil canonical paths) within the bucket
/// (D1). Broken symlinks carry a nil canonical path and therefore never
/// create ambiguity.
public struct SkillGroup: Equatable, Sendable {
    /// The skill name (from `SKILL.md`, or the link name for broken links).
    public let name: String
    /// The ownership bucket: `user` or `project:<root>`.
    public let scopeGroup: String
    /// D1: >1 distinct physical directories for one name in one bucket.
    public let ambiguous: Bool
    /// The group's placements, sorted by path.
    public let members: [DiscoveredPlacement]

    public init(
        name: String,
        scopeGroup: String,
        ambiguous: Bool,
        members: [DiscoveredPlacement]
    ) {
        self.name = name
        self.scopeGroup = scopeGroup
        self.ambiguous = ambiguous
        self.members = members
    }
}

/// Collapses discovered placements into logical skill groups.
///
/// Group order is defined: by name, then user scope before project buckets,
/// then bucket name; members within a group sort by path. The
/// OwnershipResolver turns groups plus ledger claims into D18 skills.
public enum SkillInventory {
    /// Builds the sorted skill groups from scanner output.
    public static func groups(from discovered: [DiscoveredPlacement]) -> [SkillGroup] {
        struct Bucket {
            let name: String
            let scopeGroup: String
            var members: [DiscoveredPlacement]
        }
        var buckets: [String: Bucket] = [:]
        for placement in discovered {
            let key = placement.scopeGroup + "\u{1F}" + placement.name
            if var bucket = buckets[key] {
                bucket.members.append(placement)
                buckets[key] = bucket
            } else {
                buckets[key] = Bucket(
                    name: placement.name, scopeGroup: placement.scopeGroup, members: [placement])
            }
        }
        return buckets.values
            .sorted { lhs, rhs in
                if lhs.name != rhs.name {
                    return lhs.name < rhs.name
                }
                let lhsIsUser = lhs.scopeGroup == "user"
                let rhsIsUser = rhs.scopeGroup == "user"
                if lhsIsUser != rhsIsUser {
                    return lhsIsUser
                }
                return lhs.scopeGroup < rhs.scopeGroup
            }
            .map { bucket in
                let members = bucket.members.sorted { $0.placement.path < $1.placement.path }
                let canonicalPaths = Set(members.compactMap { $0.placement.canonicalPath })
                return SkillGroup(
                    name: bucket.name,
                    scopeGroup: bucket.scopeGroup,
                    ambiguous: canonicalPaths.count > 1,
                    members: members
                )
            }
    }
}
