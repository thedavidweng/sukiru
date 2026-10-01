# 0001: Pivot to a zero-ledger referee and retire the Rust implementation

- Status: Accepted
- Date: 2026-09-14

## Context and decision

Gino was a complete Rust + GPUI reimplementation of the Vercel `skills` CLI
protocol (lockfile reads and writes, verified by differential testing against
the real CLI in CI). Competitors had already claimed the "general skills
manager" position (kitter: the same Rust + GPUI stack, 287 stars in two weeks;
aghub: a webview-based hub covering many agents). Meanwhile `gh skill`
(April 2026, GitHub CLI v2.90+) and the Vercel CLI became **two official
installers with two provenance ledgers, writing into the same agent
directories**.

We decided to stop reimplementing the protocol and rebuild as a pure Swift
(SwiftUI) native macOS app. The read side is built in-house (both ledgers plus
disk facts). The write side is delegated entirely to the official CLIs
(`npx skills` / `gh skill`). Sukiru keeps no third ledger of its own (zero
ledger). The core value is detecting and repairing messy skill libraries.

## Considered options

- **Full protocol reimplementation (previous route).** Rejected. The
  differentiation was real (byte-level parity proven by differential tests),
  but maintenance was an endless treadmill: while we pinned 1.5.9, upstream had
  reached 1.5.26. kitter also already owned the "Rust + GPUI skills manager"
  position.
- **Swift UI with the Rust core kept.** Rejected. Bridging is complex and
  conflicts with "pure native". Write-side protocol knowledge is exactly the
  burden we want to drop, and the arrival of `gh` makes the referee position
  more valuable than being yet another installer.
- **Delegation with zero ledger (chosen).** Write-side maintenance cost drops
  to zero because the official CLIs are the only writers. The trust story
  moves from "we proved parity" to "we never write ledgers". Neither Vercel nor
  GitHub is likely to read the other's ledger in depth, so a neutral referee
  position is structurally safe.

## Consequences

- The repository is converted in place (decided in the 2026-09-14 design
  review). The previous tip is preserved on the `archive/rust-gui` branch as
  reference (lock schemas, host table, detection rules). `main` becomes the
  Swift app, and the new README explains the change of route. The old GPUI
  version is never released.
- The differential-testing assets stay in the archive and are no longer a
  selling point.
- Writes on the Vercel side depend on the Node runtime on the user's machine.
  The story is "no bundled runtime; orchestrate the tools already on the
  machine". `gh skill` is a public preview: Sukiru couples loosely (invoke,
  never replicate), requires at least version 2.90.0, and probes capabilities
  at launch.
- Read-side protocol knowledge (both lockfile formats, `metadata.github-*`
  provenance, the host directory table) is still built in-house; it is the
  product. The red line is that **no write-side protocol knowledge is built,
  not a single line**.
- macOS only.
