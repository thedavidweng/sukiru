/// Collapses discovered placements into logical skills (architecture D1, D18;
/// port-reference §4 alias collapse).
///
/// Grouping key is `(scopeGroup, name)`: one logical skill per skill name per
/// ownership bucket (`user` scope, or one bucket per project root — ownership
/// never leaks across scopes). Alias placements (several placements resolving
/// to ONE canonical path, e.g. host symlinks into the canonical store) are
/// one logical skill with N placements and are never ambiguous by themselves.
///
/// A skill is `ambiguous` iff its name maps to MORE THAN ONE distinct
/// physical directory (distinct non-nil canonical paths) within the bucket
/// (D1). Broken symlinks carry a nil canonical path and therefore never
/// create ambiguity.
///
/// Ownership is NOT resolved here — that is the OwnershipResolver feature's
/// job (it needs the ledgers). Until it lands, every skill reports
/// `ownership: .ownerless`; `ambiguous` is final, because D1 needs only
/// canonical paths.
///
/// Output order is defined: by name, then user scope before project buckets,
/// then bucket name; placements within a skill sort by path.
public enum SkillInventory {
    /// Builds the D18 `skills` list from scanner output.
    public static func skills(from discovered: [DiscoveredPlacement]) -> [Skill] {
        struct Group {
            let name: String
            let scopeGroup: String
            var members: [DiscoveredPlacement]
        }
        var groups: [String: Group] = [:]
        for placement in discovered {
            let key = placement.scopeGroup + "\u{1F}" + placement.name
            if var group = groups[key] {
                group.members.append(placement)
                groups[key] = group
            } else {
                groups[key] = Group(
                    name: placement.name, scopeGroup: placement.scopeGroup, members: [placement])
            }
        }
        return groups.values
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
            .map { group in
                let members = group.members.sorted { $0.placement.path < $1.placement.path }
                let canonicalPaths = Set(members.compactMap { $0.placement.canonicalPath })
                return Skill(
                    name: group.name,
                    scope: group.scopeGroup == "user" ? .user : .project,
                    ownership: .ownerless,
                    ambiguous: canonicalPaths.count > 1,
                    placements: members.map(\.placement)
                )
            }
    }
}
