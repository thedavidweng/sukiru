import Foundation
import Testing

@testable import SukiruCore

/// InventoryScanner output-ordering guarantees (architecture §2: identical
/// scans → byte-identical reports). Split from `InventoryScannerTests` to
/// stay inside the file/type length gates.
@Suite("InventoryScanner determinism")
struct InventoryScannerDeterminismTests {
    @Test("Nested workspace roots double-inventory the shared path in a defined order")
    func nestedWorkspaceRootsTiebreakByWorkspaceID() throws {
        // Overlapping roots (a host dir nested under another workspace root)
        // discover the SAME placement path twice — once per workspace. Swift's
        // sort is not stable, so the final placement sort must break path
        // ties on workspaceID to keep output byte-deterministic.
        let tree = try TempTree()
        try tree.file(
            "a/b/skill/SKILL.md",
            contents: "---\nname: skill\ndescription: The skill.\n---\nBody.\n")
        let outer = EnumeratedWorkspace(
            workspace: Workspace(
                id: "project:/r", kind: .project, root: tree.path + "/a", installed: true),
            candidateHosts: ["claude-code"],
            scopeGroup: "project:/r"
        )
        let inner = EnumeratedWorkspace(
            workspace: Workspace(
                id: "project:/r#qoder", kind: .project,
                root: tree.path + "/a/b", installed: true),
            candidateHosts: ["qoder"],
            scopeGroup: "project:/r"
        )

        let result = InventoryScanner().scan(workspaces: [outer, inner])
        let doubled = result.placements.filter {
            $0.placement.path == tree.path + "/a/b/skill"
        }
        #expect(doubled.count == 2, "the nested root is inventoried twice (upstream parity)")
        #expect(doubled.map(\.workspaceID) == ["project:/r", "project:/r#qoder"])
    }
}
