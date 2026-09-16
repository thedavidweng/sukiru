import AppKit
import Foundation
import Quartz
import SukiruCore

/// In-place Quick Look of a `SKILL.md` via the shared `QLPreviewPanel`
/// (architecture §4.3: "Quick Look of any SKILL.md in place"). The panel is
/// app-owned UI chrome — previewing is a pure read of a file the scan already
/// inventoried, so this lives in the app layer, not SukiruCore.
///
/// One shared panel: previewing another skill reloads the same panel in
/// place; dismissing it (Esc / close button) returns focus to the app window
/// with Library selection untouched (selection state lives in `AppState`,
/// which the panel never mutates — VAL-HEALTH-023).
///
/// `QLPreviewPanel` always talks to its data source on the main thread, so
/// the item storage is `nonisolated(unsafe)` rather than actor-hopping.
final class QuickLookPreviewer: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    @MainActor static let shared = QuickLookPreviewer()

    /// The `SKILL.md` currently on offer, or nil when nothing is previewed.
    nonisolated(unsafe) private var currentItem: URL?

    /// Opens (or retargets) the Quick Look panel on the given file.
    @MainActor func preview(fileAt url: URL) {
        currentItem = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
            // A freshly-ordered panel has no item cache; without an explicit
            // reload it asks the data source for nothing and can order
            // itself straight back out.
            panel.reloadData()
            // QLPreviewPanel opens at a floating window level, which drops
            // it out of layer-0 window listings (computer-use evidence for
            // VAL-HEALTH-023 reads the window list). Demote to normal level
            // once open so the panel is enumerable like any other window.
            panel.level = .normal
            panel.title = String(
                format: String(localized: "quicklook.title %@"), url.lastPathComponent)
        }
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        currentItem == nil ? 0 : 1
    }

    nonisolated func previewPanel(
        _ panel: QLPreviewPanel!, previewItemAt index: Int
    ) -> (any QLPreviewItem)! {
        // NSURL conforms to QLPreviewItem; the panel reads the file itself.
        currentItem! as NSURL
    }
}
