import Foundation

/// Ownership identity is separate from the declared names hosts discover.
/// A package's host aliases share one entry name and dependency target.
enum PnpmSkillGrouping {
    static func groups(
        placements: [DiscoveredPlacement], locks: [ScopeLockClaim], pnpm: PnpmOwnershipEvidence
    ) -> [SkillGroup] {
        var ordinary: [DiscoveredPlacement] = []
        var packages: [String: [DiscoveredPlacement]] = [:]
        for member in placements {
            guard let package = pnpm.verified[member.placement.path] else {
                ordinary.append(member)
                continue
            }
            let entry = (package.placement as NSString).lastPathComponent
            let key = member.scopeGroup + "\u{1F}" + entry + "\u{1F}" + package.target
            packages[key, default: []].append(member)
        }
        var result = SkillInventory.groups(from: ordinary, locks: locks)
        for key in packages.keys.sorted() {
            let members = (packages[key] ?? []).sorted {
                ($0.placement.path, $0.workspaceID) < ($1.placement.path, $1.workspaceID)
            }
            guard let first = members.first else { continue }
            result.append(
                SkillGroup(
                    name: first.name, scopeGroup: first.scopeGroup, ambiguous: false,
                    members: members))
        }
        return result.sorted {
            let left = (
                $0.name, $0.scopeGroup == "user" ? "" : $0.scopeGroup,
                $0.members.first?.placement.path ?? ""
            )
            let right = (
                $1.name, $1.scopeGroup == "user" ? "" : $1.scopeGroup,
                $1.members.first?.placement.path ?? ""
            )
            return left < right
        }
    }
}
