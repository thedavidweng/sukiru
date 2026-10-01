import AppKit
import Foundation
import Quartz
import SukiruCore

/// In-place Quick Look of a `SKILL.md` via the shared `QLPreviewPanel`.
/// The panel is
/// app-owned UI chrome — previewing is a pure read of a file the scan already
/// inventoried, so this lives in the app layer, not SukiruCore.
///
/// One shared panel: previewing another skill reloads the same panel in
/// place; dismissing it (Esc / close button) returns focus to the app window
/// with Library selection untouched (selection state lives in `AppState`,
/// which the panel never mutates).
///
/// `QLPreviewPanel` always talks to its data source on the main thread, so
/// the item storage is `nonisolated(unsafe)` rather than actor-hopping.
final class QuickLookPreviewer: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    @MainActor static let shared = QuickLookPreviewer()

    /// The `SKILL.md` currently on offer, or nil when nothing is previewed.
    nonisolated(unsafe) private var currentItem: URL?

    /// Opens (or retargets) the Quick Look panel on the given file. ⌘Y is a
    /// TOGGLE: calling this while the panel is visible closes it instead of
    /// retargeting, so one shortcut both opens and dismisses it.
    @MainActor func preview(fileAt url: URL) {
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.close()
            return
        }
        currentItem = url
        installEscapeMonitor()
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        // A freshly-ordered panel has no item cache; without an explicit
        // reload it asks the data source for nothing and can order itself
        // straight back out.
        panel.reloadData()
        // QLPreviewPanel opens at a floating window level, which drops it
        // out of layer-0 window listings (computer-use verification
        // reads the window list). Demote to normal level once
        // open so the panel is enumerable like any other window.
        panel.level = .normal
        panel.title = String(localized: "quicklook.title \(url.lastPathComponent)")
    }

    /// The installed Escape key monitor (kept for the app's lifetime; inert
    /// whenever the panel is closed).
    private var escapeMonitor: Any?

    /// Keyboard-only Quick Look dismiss. QLPreviewPanel does
    /// not close on Escape by itself (only its close button works), so a
    /// local key-down monitor closes it before the event is dispatched. The
    /// panel belongs to this app, so its key events pass through the local
    /// monitor even while the panel is key.
    @MainActor private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 53 = kVK_Escape.
            guard event.keyCode == 53,
                let panel = QLPreviewPanel.shared(),
                panel.isVisible
            else { return event }
            panel.close()
            return nil
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
