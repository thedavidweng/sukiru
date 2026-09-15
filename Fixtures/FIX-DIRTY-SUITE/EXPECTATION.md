# FIX-DIRTY-SUITE — expectation (M3 health-area workhorse)

One tree triggering several rules at once, with findings in BOTH scopes:

- user scope (`.home`, claude-code detected via config.json):
  `rotted-link` dangling symlink -> `broken-symlink` (action);
  `gh-owned` github-provenanced -> `dangerous-removal-surface` (action);
  `user-orphan` no ledger -> `files-without-lock` (info).
- project scope (`proj`):
  `drifted` edited after install -> `vercel-lock-drift` (action);
  `proj-orphan` no ledger -> `files-without-lock` (info).

Scan with SUKIRU_HOME=<this>/.home SUKIRU_ROOTS=<this>/proj.

A correct scan MUST exit 0 with exactly these EIGHT findings: the five above
PLUS a `dangerous-removal-surface` advisory for each ownerless name
(`user-orphan`, `proj-orphan`, `rotted-link`) — VAL-SCAN-030 fires on
gh-owned AND ownerless skills. Two severity levels render (action + info);
the dangling link additionally surfaces as a `broken-symlink` ISSUE. Each
finding carries its rule's concrete evidence. Ownership: gh-owned=github,
drifted=vercel, the two orphans and rotted-link=ownerless. The app drives
its grouped-findings, severity-display, per-workspace filter,
keyboard-disclosure, and selection-persistence assertions off this tree.
