# Sukiru

[![CI](https://github.com/thedavidweng/sukiru/actions/workflows/ci.yml/badge.svg)](https://github.com/thedavidweng/sukiru/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/thedavidweng/sukiru)](https://github.com/thedavidweng/sukiru/releases)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)

Sukiru is a fast, tiny, native macOS app that checks and repairs your coding
agents' skill libraries. It manages skills by orchestrating the two official
installers, `npx skills` and `gh skill`, and never keeps an install ledger of
its own.

## Why Sukiru

Agent skills (directories with a `SKILL.md`) are installed by two official
tools that keep separate records:

- **Vercel `skills`** (`npx skills`) records installs in lockfiles
  (`skills-lock.json` per project, `~/.agents/.skill-lock.json` globally).
- **GitHub CLI** (`gh skill`) records provenance inside each skill's
  `SKILL.md` frontmatter (`metadata.github-*`).

Both write into the same agent directories, and neither reads the other's
records. In controlled experiments ([collision matrix](docs/collision-matrix.md))
this silently produced stale lock hashes, skills claimed by both tools,
diverging copies, and cross-tool deletions. Hand-copied skills add a third
category that no installer can update or cleanly remove.

Sukiru reads both ledgers plus what is actually on disk, works out who owns
each skill, explains every problem in plain language, and routes each fix to
the tool that owns the skill.

## Features

- **Health report.** Problems are grouped into kinds you can act on: stale
  lock records, broken links, copies where links belong, diverging copies,
  skills with unknown sources, and ownership conflicts. Healthy layouts and
  standing notices fold into Notes.
- **One-click fixes.** Fix one problem or Fix All. Every fix becomes one
  batch that you confirm once, in plain language, with the exact commands one
  click away.
- **Safe by construction.** Every batch runs as snapshot → execute → diff,
  with one-click rollback. The last 10 snapshots are kept.
- **Library.** See each skill's owner, provenance, pinned ref, and where it is
  placed across agents. Switch a skill between link and copy mode.
- **Search and install.** Search skills.sh and `gh skill search`, preview
  `SKILL.md`, then install with the installer you choose, through the same
  confirm → snapshot → rollback pipeline.
- **Adopt unknown skills.** Find candidate sources for hand-copied skills and
  bring them under an installer.
- **Works without the CLIs.** With neither Node.js nor `gh` installed, Sukiru
  is still a complete read-only health checker.
- **Native.** Pure Swift, SwiftUI, and AppKit with system controls only, so it
  follows your appearance, accessibility settings, and Liquid Glass on
  macOS 26. Available in English and Simplified Chinese.

## Design principles

- **Zero ledger.** Sukiru never writes installer records. Ledger changes go
  through the official CLIs only. Sukiru performs file operations directly
  only for link management that no CLI offers (deleting a broken link,
  replacing a copy with a link, turning a link into a copy), always inside a
  snapshot.
- **Ownership routes repairs.** There is no global "backend" setting. A skill
  owned by `npx skills` is repaired with `npx skills`, and the same goes for
  `gh skill`.
- **No background activity.** No filesystem watchers and no remote update
  checks. The app shows state at launch and when you click Refresh.
- **Deterministic.** The same disk state always produces the same report.
- **Malformed data is a reported problem, never a crash.**

## Requirements

- macOS 14 Sonoma or later on Apple silicon.
- Optional, to make changes:
  - [Node.js](https://nodejs.org/en/download) for `npx skills`.
  - [GitHub CLI](https://cli.github.com) 2.90.0 or later for `gh skill`.

Sukiru detects both tools at launch and disables only the actions that need a
missing tool.

## Installation

**Homebrew (recommended)**

```bash
brew install --cask thedavidweng/tap/sukiru
```

**Direct download**

Download `Sukiru.dmg` from
[GitHub Releases](https://github.com/thedavidweng/sukiru/releases), open it,
and drag **Sukiru.app** into `/Applications`. Each release lists SHA-256
checksums in `checksums.txt`.

Release builds are not yet notarized by Apple. If macOS says Sukiru cannot be
opened, open **System Settings › Privacy & Security** and click
**Open Anyway** next to the Sukiru message.

## Getting started

1. Launch Sukiru. It scans your user-level skill directories automatically.
2. To include project-level skills, add your project folders as project roots
   (**View › Add Project Root…**, ⇧⌘A, or in Settings).
3. Open **Health** to see problems and what caused them. Click a problem's
   fix button, or **Fix All**.
4. Review the confirmation sheet and confirm. To undo, use the result page or
   **Repair › Roll Back Selected Batch**.

## Privacy

Sukiru has no accounts, analytics, or telemetry. It reads local files and
runs the official CLIs on your machine. It connects to the network only when
you search (the skills.sh search API and `gh skill search`), preview a
skill's `SKILL.md` from GitHub, or run a CLI command that needs the network.
Snapshots and execution records stay in
`~/Library/Application Support/Sukiru`.

## Command-line interface

The `sukiru-cli` tool exposes the same engine for scripting and testing:

```bash
swift run sukiru-cli scan           # JSON health report
swift run sukiru-cli capabilities   # detected installers and versions
swift run sukiru-cli batch …        # build or run a repair batch from a decisions file
swift run sukiru-cli rollback …     # restore a batch snapshot
```

`SUKIRU_HOME` replaces `$HOME` for all path resolution, and `SUKIRU_ROOTS`
adds colon-separated project roots. See [CONTRIBUTING.md](CONTRIBUTING.md)
for details.

## Building from source

```bash
swift test                 # core library and CLI tests
Scripts/build-app.sh       # generate the Xcode project and build Sukiru.app
Scripts/run-app.sh         # run the debug app
```

Building needs Xcode 26 or later (Swift 6.2) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen). See
[CONTRIBUTING.md](CONTRIBUTING.md) for the full workflow, quality gates, and
test safety rules.

## Documentation

- [Glossary](CONTEXT.md): the domain terms used in code and UI.
- [Architecture decision records](docs/adr/README.md).
- [Collision matrix](docs/collision-matrix.md): experiments on how the two
  official installers interact.
- [Release notes](https://github.com/thedavidweng/sukiru/releases).

## Project history

Sukiru began as "Gino", a Rust/GPUI reimplementation of the `skills` CLI. In
September 2026 it was rebuilt as a native Swift app that delegates all
installer writes to the official tools ([ADR-0001](docs/adr/0001-pivot-to-zero-ledger-referee.md)).
The retired implementation is kept for reference on the
[`archive/rust-gui`](https://github.com/thedavidweng/sukiru/tree/archive/rust-gui)
branch.

## Contributing and support

- Bugs and feature requests: [GitHub Issues](https://github.com/thedavidweng/sukiru/issues).
- Contributions: read [CONTRIBUTING.md](CONTRIBUTING.md) and the
  [Code of Conduct](CODE_OF_CONDUCT.md).
- Security issues: follow [SECURITY.md](SECURITY.md). Do not open a public
  issue.

## License

Copyright © 2026 David Weng. Licensed under the [Apache License 2.0](LICENSE).

Agent logos identify compatible tools and remain the property of their
owners. Their sources and licenses are listed in
[`App/Resources/AgentIcons-LICENSE.txt`](App/Resources/AgentIcons-LICENSE.txt).
