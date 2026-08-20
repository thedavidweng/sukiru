# Gino 1.0 release plan

Normative product contract: `docs/spec.md`.
Pinned upstream: `vercel-labs/skills@1.5.9` (`compatibility.toml`).

This document is the remaining-work DAG for shipping 1.0. Agents must read
`docs/spec.md` and this file before editing. Do not invent a second install
protocol. Do not write files except through Planner → Apply.

## Current baseline

- Rust core exists: protocol, inventory, planner, executor, git, metadata, GPUI shell.
- 42 unit tests pass. Clippy and rustfmt are clean.
- Not 1.0: agent registry and source parser are incomplete vs 1.5.9; UI is a
  list shell; marketplace, settings, packaging, and CI are missing.

## Slices (dependency order)

### S1 — Protocol lock-in

- Complete `src/agents.rs` to match 1.5.9 agent ids, paths, env homes, and detection.
- Complete `src/protocol.rs` / `src/source.rs` source forms: local, github,
  gitlab, git, well-known, `github:`/`gitlab:` prefixes, `#ref`, `@skill`,
  `owner/repo/path`, GitLab `/-/tree/`.
- Equivalent `npx skills` command generation (`src/command.rs`).
- Tests for every source form and agent home override.

### S2 — Application services

- Marketplace: `GET https://skills.sh/api/search?q=&limit=` (`src/marketplace.rs`).
- Platform: reveal-in-file-manager, external editor, folder picker, keychain
  via OS tools, sanitized log zip (`src/platform.rs`).
- Preferences persist in SQLite (theme, text size, editor, snapshot retention,
  backup remote, push mode, size policy, proxy, agent order).
- Snapshot root: `~/.gino/snapshots` (not `$TMPDIR`).

### S3 — Product UI

All §6.1 surfaces must be real, not the same Skill list:

1. Library + read-only detail (SKILL.md / README.md preview, placements,
   hashes, equivalent CLI, Reveal, Open in Editor).
2. Marketplace search + multi-select install planning.
3. Global / Projects / Agents / Custom Workspaces (register, remove bookmark).
4. Duplicates workspace with keep-one planning.
5. Presets and Tags.
6. Pending Changes review + `Apply N changes` + Unavailable gating.
7. Backup: commit mode, fetch, propose sync, restore, conflict choices.
8. Activity and Settings.
9. Exit protection: Apply and Quit / Discard and Quit / Cancel.
10. Keyboard: sidebar, list, refresh, apply, conflict, dialogs. Visible focus.

### S4 — Release hardening

- README, MIT LICENSE, `.github/workflows/ci.yml` (fmt, clippy, test).
- Packaging notes/scripts for macOS/Windows/Linux (no Node.js).
- Version `1.0.0`.
- `cargo test`, `cargo clippy -D warnings`, `cargo fmt --check` green.

## Invariants

- Filesystem is the source of truth. SQLite never invents installed Skills.
- No implicit mutation. Refresh is read-only.
- One Apply = one snapshot + one Git commit. Failed Apply rolls back, no commit.
- Push failure keeps the local commit (`Not pushed`).
- Preserve unknown lockfile fields.
- No telemetry. No self-update.

## Done

Product is releasable when §28 Definition of Done items 1–13 hold on this
machine, Windows/Linux compile (`cargo check` at least), CI exists, and
artifacts can be built without Node.js.
