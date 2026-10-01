# 0003: Name the product Sukiru (formerly Gino)

- Status: Accepted
- Date: 2026-09-14

## Context and decision

The original name, Gino (from the Japanese reading of "skill"), collides with
an existing Python asyncio ORM, `python-gino/gino`, which target users would
find first when searching GitHub. The repository was still private and
unreleased, so renaming cost nothing (decided in the 2026-09-14 design
review).

The new name is **Sukiru** (スキル, the katakana loanword for "skill"). It has
no meaningful collision on GitHub (only one personal practice project and a
single-repository organization), follows the same naming logic, and matches
the product story of retiring the old route for a new one. Before public
launch, check whether `sukiru.app` / `sukiru.com` are available
(`sukiru.co` already exists; a minor flag).

## Consequences

- Rename the remote together with the repository (a GitHub rename of a
  private repository loses no history).
- Historical passages in ADRs keep the name "Gino" when they refer to the old
  Rust implementation. The current product is always called Sukiru.
- Positioning statement (decided 2026-09-14, the pragmatic version):
  "**Sukiru is the fast and tiny macOS native skill manager that manages your
  skills by orchestrating npx skills and gh skill.**" The tagline is
  deliberately plain (three more marketing-heavy candidates were rejected).
  The referee story, the two ledgers, and the collision-matrix evidence belong
  in the README body.
