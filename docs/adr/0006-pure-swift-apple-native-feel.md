# 0006: Pure Swift and an Apple first-party feel (the native red line)

- Status: Accepted (language setting amended 2026-10-01)
- Date: 2026-09-20

## Context and decision

This ADR turns ADR-0001's "pure Swift native macOS app" from a narrative into
**verifiable engineering constraints**. The only implementation language is
Swift, the UI uses only Apple system frameworks, and the goal is that users
cannot tell it apart from Apple's own tools (Finder, System Settings, the Xcode
Organizer).

## Constraints (the red line)

- **Language and frameworks.** Swift only. The UI uses only SwiftUI, AppKit,
  and Apple system frameworks. No webview, Electron, Tauri, React Native, or
  Flutter shells; no non-Apple rendering stack (GPUI or similar); no Mac
  Catalyst port.
- **No third-party dependencies in the UI layer.** No third-party component
  libraries, icon packs, font packs, or animation libraries. The few brand
  logos needed to identify external coding agents are content resources, kept
  with their source and license, and never used as control icons. Non-UI
  dependencies remain subject to the AGENTS.md rule that every dependency must
  justify its maintenance and size cost (today only Yams, required for reading
  YAML).
- **System controls use system assets only.** Semantic colors
  (`Color.primary`, `.secondary`, `.accentColor`, …), SF Symbols, and the
  system font. External agent logos only represent their agents. Never
  hard-code colors, corner radii, or shadow values to imitate the system look.
- **No custom chrome.** No custom title bars, sidebars, scroll bars, switches,
  or progress bars. Window structure uses `NavigationSplitView`, settings use
  the `Settings` scene, global actions use the window toolbar, modals use
  system sheets, alerts, and `confirmationDialog`, and previews go through
  Quick Look.
- **Inherit new capabilities; never imitate them.** New system looks (such as
  Liquid Glass in macOS 26) must come automatically from standard controls.
  When a new API is needed, gate it with `#available` as a progressive
  enhancement, falling back to standard behavior on older systems. Any
  implementation that "draws its own glass" violates the red line.
- **Follow system preferences.** Light and dark mode, accent color, Increase
  Contrast, Reduce Transparency, Reduce Motion, accessibility text sizes, and
  VoiceOver labels all follow the system. There is no in-app theme switch.
  Localization (`en` + `zh-Hans`) follows the system language by default.
- **Keyboard and menus.** The main menu bar holds every command with its
  shortcut, and `⌘,` opens the standard Settings window. No action requires a
  mouse.
- **App icon.** A single Icon Composer (`.icon`) source, which must include a
  base `fill` and layer shadows so the icon stays visible on both light and
  dark backgrounds. (An earlier regression removed the `fill` and zeroed the
  shadows, making the icon invisible on a light Dock.)

## Amendment (2026-10-01): language setting

Settings › General offers a language picker that defaults to following the
system. It writes the app's own `AppleLanguages` default, the same per-app
setting that System Settings › Language & Region › Applications writes, and
takes effect after a relaunch. It adds no custom localization mechanism, so it
stays within the red line.

## Consequences

- When a "special" visual is wanted, change the design to fit system
  controls; never draw custom controls to match a mockup. Visual
  differentiation is not where this product competes (the referee role is).
- Review checklist (per pull request): no third-party dependencies in the UI
  layer, no hard-coded colors or materials, no custom chrome, every new system
  API gated by `#available`, every new string in both catalogs, and every new
  control with an accessibility identifier and a `.help` description.
- Gates reuse the existing toolchain: `swift-format`, `swiftlint --strict`,
  and `swift test`. Icon visibility is checked quantitatively by the average
  brightness of the built icon, not by eye.
- macOS only (as in ADR-0001). Native quality is never reduced for
  cross-platform reuse; iOS and iPadOS versions are not planned.
- Adapting to a new macOS release therefore reduces to "raise the SDK, run the
  gates, and audit the `#available` gates", not a UI redraw.
