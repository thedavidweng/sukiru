# 0005: Unify vocabulary and dispose of legacy assets

- Status: Accepted
- Date: 2026-09-14

## Decision

Conflicts between the glossary in the old `spec.md` (kept on the archive
branch) and the new [`CONTEXT.md`](../../CONTEXT.md) are resolved as follows:

- **Untracked Skill → Ownerless Skill.** The `CONTEXT.md` entry is the
  standard; the old term is retired.
- **Pending Change / Apply Batch.** The names stay (the UI keeps them), but
  the meaning becomes a **command batch**: a sequence of official CLI commands
  to run and their expected effects, no longer a file-operation plan.
- **The `agents.rs` host table** is absorbed as data by Sukiru's read side.
  The 13 public read-side entry points in `protocol.rs` serve as porting
  references; write-side functions are not ported. (The table was cited as 116
  hosts at the time; the absorbed table has 56. See ADR-0004.)
- **`compatibility.toml` is retired.** Sukiru no longer pins upstream versions.
  Using the latest version plus capability probing (ADR-0002 / ADR-0004)
  replaces the pinning treadmill.
- **Differential end-to-end tests** (`tests/e2e_cli_diff.rs`) stay in the
  archive for reference and are no longer maintained.
- **Collision matrix experiments** are approved to run immediately (controlled
  mixed installs using only the CLIs, no product code). Results go to
  [`docs/collision-matrix.md`](../collision-matrix.md) to calibrate the v1
  detection rules.
