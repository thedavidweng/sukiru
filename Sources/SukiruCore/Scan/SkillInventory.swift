/// One logical skill name within one ownership bucket, before ownership
/// resolution (architecture D1 as refined by D23; port-reference §4 alias
/// collapse).
///
/// Grouping key is `(scopeGroup, name)`: one logical skill per skill name per
/// ownership bucket (`user` scope, or one bucket per project root — ownership
/// never leaks across scopes). Alias placements (several placements resolving
/// to ONE canonical path, e.g. host symlinks into the canonical store) are
/// one logical skill with N placements and are never ambiguous by themselves.
///
/// A group is `ambiguous` per the D23 refined trigger (see
/// `SkillInventory.isAmbiguous`): the naive ">1 distinct canonical paths"
/// reading of D1 is wrong because every stock copy-mode install has two
/// physical copies. Broken symlinks carry no canonical path and no content
/// hash and therefore never create ambiguity.
public struct SkillGroup: Equatable, Sendable {
    /// The skill name (from `SKILL.md`, or the link name for broken links).
    public let name: String
    /// The ownership bucket: `user` or `project:<root>`.
    public let scopeGroup: String
    /// D23: the bucket's unexplained placements hold ≥2 distinct content
    /// hashes (computed by `SkillInventory.groups`, which needs the scope's
    /// lock claim).
    public let ambiguous: Bool
    /// The group's placements, sorted by (path, workspaceID).
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
    /// Builds the sorted skill groups from scanner output. `locks` feed the
    /// D23 ambiguity trigger: whether the vercel ledger claims a name decides
    /// which placements are hash-explained by the canonical store.
    public static func groups(
        from discovered: [DiscoveredPlacement],
        locks: [ScopeLockClaim] = []
    ) -> [SkillGroup] {
        var claims: [String: ScopeLockClaim] = [:]
        for claim in locks {
            claims[claim.scopeGroup] = claim
        }
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
                // (path, workspaceID): Swift's sort is not stable, and
                // overlapping roots can place one path in two workspaces.
                let members = bucket.members.sorted {
                    ($0.placement.path, $0.workspaceID) < ($1.placement.path, $1.workspaceID)
                }
                return SkillGroup(
                    name: bucket.name,
                    scopeGroup: bucket.scopeGroup,
                    ambiguous: isAmbiguous(
                        name: bucket.name, members: members, claim: claims[bucket.scopeGroup]),
                    members: members
                )
            }
    }

    /// The D23 refined ambiguity trigger (architecture §11), per name per
    /// scope after alias collapse.
    ///
    /// Placements partition into EXPLAINED and UNEXPLAINED. A placement is
    /// explained when:
    /// (a) the vercel lock claims the name AND the placement is hash-
    ///     identical (transitively, via content-hash equality) to the
    ///     placement in the scope's canonical store — the workspace whose id
    ///     IS the bucket key (`user` / `project:<root>`), the same identity
    ///     the impostor and divergence rules use; or
    /// (b) the placement carries gh frontmatter provenance, or is hash-
    ///     identical to one that does.
    ///
    /// The name is AMBIGUOUS iff the unexplained placements contain ≥2
    /// distinct content hashes. Consequences (D23): stock copy-mode installs
    /// are vercel-owned exact duplicates, never ambiguous; a gh-overwritten
    /// copy is double-booked, not ambiguous; two divergent copies with no
    /// ledger story for either ARE ambiguous; a lone divergent copy alongside
    /// anchored ones is `canonical-host-divergence`, not ambiguity.
    ///
    /// Placements without a content hash (broken symlinks, hash failures)
    /// cannot establish identity and participate in neither partition.
    private static func isAmbiguous(
        name: String,
        members: [DiscoveredPlacement],
        claim: ScopeLockClaim?
    ) -> Bool {
        let hashed: [(member: DiscoveredPlacement, hash: String)] = members.compactMap { member in
            guard member.placement.kind != .brokenSymlink,
                let hash = member.placement.contentHash
            else { return nil }
            return (member, hash)
        }
        let lockClaims = claim?.lock.entries[name] != nil
        // D23(a) anchors on THE canonical-store placement. Scanner invariant
        // this relies on: one skills dir per workspace per name, so at most
        // one placement per name carries `workspaceID == scopeGroup`.
        let canonicalHash = hashed.first { $0.member.workspaceID == $0.member.scopeGroup }?.hash
        let ghHashes = Set(hashed.filter { $0.member.githubProvenance != nil }.map { $0.hash })
        var unexplainedHashes: Set<String> = []
        for (member, hash) in hashed {
            if lockClaims, let canonicalHash, hash == canonicalHash {
                continue
            }
            if member.githubProvenance != nil || ghHashes.contains(hash) {
                continue
            }
            unexplainedHashes.insert(hash)
        }
        return unexplainedHashes.count >= 2
    }
}
