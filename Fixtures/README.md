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
`impostor-copy`, `FIX-USER-SCOPE-COPY-MODE`.

M3 health-area trees (app-level assertions): `FIX-OWNERSHIP-QUAD` (five skills,
one per ownership state — two github: pinned + unpinned), `FIX-SCOPES`,
`FIX-MULTI-HOST`, `FIX-DRIFT`, `FIX-DOUBLE-BOOKED`, `FIX-SYMLINK`,
`FIX-HOST-DIVERGENCE`, `FIX-DIRTY-SUITE`, `FIX-MUTABLE`.

M4 repair-area trees: `FIX-SCOPES-CROSS` (VAL-CROSS-017/018 — the same skill
name with DIFFERENT ownership per scope, findings in both scopes; committed
because FIX-SCOPES is all-vercel/zero-findings and cannot stand in for it),
`FIX-ADOPT` (VAL-REPAIR-045 — an ownerless skill whose name matches the real
upstream test repo's `stale-docs-cleanup`, so the adopt shape re-anchors
provenance onto the existing directory).

Project-scope trees (`scope-isolation`, `multi-host-inventory`, `own-vercel`,
`prov-cross-ws`, `lock-drift`, `divergence-canonical`, `lock-version-old`,
`clean-copy-mode`, `FIX-SCOPES`, `FIX-SCOPES-CROSS`, `FIX-DRIFT`,
`FIX-HOST-DIVERGENCE`, `FIX-DIRTY-SUITE`) use the CM-style two-part layout:
scan them with
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

## Capability PATH-stub environments (checked in)

`cap-gh-ok`, `cap-gh-old`, `cap-gh-probe-fail`, `cap-gh-absent`, `cap-npx-ok`,
`cap-npx-absent`, `cap-neither` are NOT scan fixtures: each holds only a `bin/`
of POSIX-sh stub executables (controlled `gh`/`npx` output, no network) plus
its `EXPECTATION.md`. Compose a capability environment by concatenating bin
dirs onto PATH:

```
PATH="$PWD/Fixtures/cap-gh-ok/bin:$PWD/Fixtures/cap-npx-ok/bin:/usr/bin:/bin" \
  sukiru-cli capabilities --format json
```

An "absent" fixture contributes an empty `bin/`; combine freely (e.g.
`cap-gh-absent/bin:cap-npx-ok/bin` = gh absent, npx fine). Set
`SUKIRU_STUB_TRANSCRIPT=<file>` to make every stub log its invocations —
the validator's evidence (VAL-SCAN-037/057). `cap-gh-probe-fail` (gh 2.100.0,
failing `gh skill --help`) is the VAL-SCAN-057 environment, an addition to
the contract's six-name legend. These trees are also rebuilt by
`build-handbuilt.sh`.

## CLI-generated collision-matrix corpus (checked in)

`CM-1, CM-2, CM-3, CM-5, CM-6, CM-8` are produced by scripting the REAL pinned
`skills@1.5.26` CLI and `gh` in isolated sandbox HOMEs, reproducing the dirty
states in `docs/collision-matrix.md`. The corpus IS committed (since
`seam-a-corpus-validation`) so the snapshot suite and validators can run
offline; regenerate it — never hand-edit it — with:

```
Scripts/fixtures/generate.sh --check          # verify tooling + isolation, no network
SUKIRU_E2E=1 GH_TOKEN="$(gh auth token)" \
  Scripts/fixtures/generate.sh [TARGET_DIR]   # full generation (defaults to ./Fixtures)
```

Each `CM-*` dir holds `proj/` (the generated project tree; scan with
`SUKIRU_HOME=<CM>/.home SUKIRU_ROOTS=<CM>/proj`), a `PIN.txt` recording the CLI
versions used, and an `EXPECTATION.md`. Generation is gated on `SUKIRU_E2E=1`
and a canary asserts the user's real `$HOME` is never mutated. Generator
hygiene: the sandbox `.home` is reset to a pristine `.gitkeep`'d dir and CLI
transcripts are dropped after each scenario — the pinned CLI otherwise leaves
a global lock (a spurious user-scope `lock-without-files` finding on scans)
plus npm/mise/gh caches in it.

## Expectation snapshots (checked in)

`expectations/<fixture>.scan.json` holds the path-normalized
(`<FIXTURE>/...`) `sukiru-cli scan --format json` stdout for every FIX-* and
CM-* tree plus `scope-isolation`. `CorpusExpectationTests` compares fresh
scans byte-for-byte against them; refresh after intentional engine or corpus
changes with:

```
SUKIRU_UPDATE_SNAPSHOTS=1 swift test --filter CorpusExpectationTests
```

Record mode refuses to arm when `CI` is set (record-then-compare always
passes, so a leaked flag in validation would bless regressions); under CI the
suite asserts the committed snapshots instead.

## Smoke test

`Tests/SukiruCoreTests/FixtureCorpusTests.swift` asserts every required
hand-built tree exists with its note, and that the read engine loads every
fixture directory (hand-built or generated) without throwing.
