# 0002: Backend model: capability detection, ownership routing, installer choice, and graceful degradation

- Status: Accepted
- Date: 2026-09-14

## Context and decision

The two official CLIs (`npx skills`, `gh skill`) are not interchangeable
backends, because neither can see the other's ledger. To `gh`, a skill in the
Vercel lock was "installed by another tool" (its update skips it or asks to
adopt it). To `npx skills update`, a skill with frontmatter provenance is
unmanaged.

Therefore the app **has no global backend setting**:

- At launch it probes capabilities (`gh` ≥ 2.90.0, Node availability).
- Repair, update, and uninstall are routed by each skill's **ownership** to the
  CLI that claims it.
- Only for a new install does the user choose the installer (the tool chosen
  decides which ledger records it).
- When a tool is missing, the app degrades to read-only health checks. With
  neither CLI present it is still a complete detector.

## Considered options

- **Global backend preference (user picks one).** Rejected. The app would use
  the wrong tool on skills in the other ledger. Example: choosing `gh` to update
  a skill in the Vercel lock gets it skipped or creates a double-booked skill.
  Ownership is a fact, not a preference.

## Consequences

- Repair correctness depends directly on how reliably the read-side core
  determines ownership (echoing the read-side red line in ADR-0001).
- Fixing a double-booked skill must ask the user which ledger to keep.
  Adopting an ownerless skill is a user decision (which ledger adopts it).
- On a bare machine (no Node, no `gh`), Sukiru is a complete health checker.
  The app is a read-only diagnostic first and an orchestrator second.
