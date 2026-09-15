# Fixtures — seam-A test corpus

Two kinds of fixtures back the seam-A (read engine) tests and validators.

## Hand-built trees (checked in)

Each is a fake `$HOME` (point the CLI/app at it with `SUKIRU_HOME=<dir>`, plus
`SUKIRU_ROOTS` where a project scope is needed). Every tree ships an
`EXPECTATION.md` stating exactly what a correct scan must report.

Regenerate them deterministically (idempotent, no network, never touches your
real `$HOME`):

```
Scripts/fixtures/build-handbuilt.sh [FIXTURES_DIR]   # defaults to ./Fixtures
```

Trees: `FIX-EMPTY`, `FIX-CLEAN`, `FIX-INTERNAL`, `FIX-MALFORMED`, `FIX-GARBAGE`,
`FIX-DANGER`, `FIX-BIG`, `FIX-DUPLICATES`, `FIX-LOCK-NO-FILES`,
`FIX-FILES-NO-LOCK`, `FIX-AMBIGUOUS`, `alias-link-mode`, `symlink-mode`,
`skillmd-invalid-a`…`skillmd-invalid-f`, `skillmd-early-close`,
`leftover-spray`, `leftover-dsstore`, `empty-marker`, `scope-isolation`,
`multi-host-inventory`, `ignore-list`, `own-vercel`, `own-github`, `own-double`,
`own-per-project`, `prov-cross-ws`, `lock-unknown-fields`, `lock-drift`,
`divergence-canonical`, `lock-version-old`, `lock-malformed`, `clean-copy-mode`,
`impostor-copy`.

Project-scope trees (`scope-isolation`, `multi-host-inventory`, `own-vercel`,
`prov-cross-ws`, `lock-drift`, `divergence-canonical`, `lock-version-old`,
`clean-copy-mode`) use the CM-style two-part layout: scan them with
`SUKIRU_HOME=<tree>/.home SUKIRU_ROOTS=<tree>/proj`. Everything else IS the
fake home.

## Contract-name aliases

Three names in the validation-contract scan-area legend are covered by
existing trees rather than dedicated directories. Validators MUST use this
canonical mapping:

| Legend name     | Proving tree  | Where the defect lives |
|-----------------|---------------|------------------------|
| `broken-link`   | `FIX-GARBAGE` | `.claude/skills/rotted -> /nonexistent/rotted-target` (dangling symlink) |
| `unreadable-dir`| `FIX-GARBAGE` | `.agents/skills/locked-dir` (chmod 000 via `prepare-runtime.sh`) |
| `dup-alias`     | `FIX-DUPLICATES` | the `alias-demo` group (canonical dir + two host symlinks) |

Every other legend name maps 1:1 to a same-named tree above (or to a `CM-*` /
`hash-parity` generated fixture).

Some states cannot be stored in git (a chmod-000 unreadable directory). Apply
them at runtime with:

```
Scripts/fixtures/prepare-runtime.sh [FIXTURES_DIR]
```

## CLI-generated collision-matrix corpus (regenerated on demand)

`CM-1, CM-2, CM-3, CM-5, CM-6, CM-8` are produced by scripting the REAL pinned
`skills@1.5.26` CLI and `gh` in isolated sandbox HOMEs, reproducing the dirty
states in `docs/collision-matrix.md`. They are network-derived and reproducible,
so they are gitignored rather than committed.

```
Scripts/fixtures/generate.sh --check          # verify tooling + isolation, no network
SUKIRU_E2E=1 GH_TOKEN="$(gh auth token)" \
  Scripts/fixtures/generate.sh [TARGET_DIR]   # full generation (defaults to ./Fixtures)
```

Each `CM-*` dir holds `proj/` (the generated project tree; scan with
`SUKIRU_HOME=<CM>/.home SUKIRU_ROOTS=<CM>/proj`), a `PIN.txt` recording the CLI
versions used, and an `EXPECTATION.md`. Generation is gated on `SUKIRU_E2E=1`
and a canary asserts the user's real `$HOME` is never mutated.

## Smoke test

`Tests/SukiruCoreTests/FixtureCorpusTests.swift` asserts every required
hand-built tree exists with its note, and that the read engine loads every
fixture directory (hand-built or generated) without throwing.
