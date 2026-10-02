<div align="center">
  <img src="Resources/AppIcon.webp" alt="Sukiru Icon" width="128" height="128" />
  <h1>Sukiru</h1>
  <p><strong>A fast, tiny, native macOS app that checks and repairs your coding agents' skill libraries.</strong></p>

  <p>
    <a href="https://github.com/thedavidweng/sukiru/releases"><img src="https://img.shields.io/github/v/release/thedavidweng/sukiru?color=007AFF&label=Release&logo=apple" alt="GitHub Release" /></a>
    <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-14.0%2B%20Sonoma-black?logo=apple" alt="macOS 14+" /></a>
    <a href="https://www.swift.org"><img src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white" alt="Swift 6.2" /></a>
    <a href="#-installation"><img src="https://img.shields.io/badge/Homebrew-thedavidweng%2Ftap-FBB040?logo=homebrew" alt="Homebrew Tap" /></a>
    <a href="PRIVACY.md"><img src="https://img.shields.io/badge/Privacy-No%20Telemetry-success" alt="No Telemetry" /></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache--2.0-blue" alt="License: Apache-2.0" /></a>
  </p>

  <p>
    <a href="README.md"><strong>English</strong></a> •
    <a href="README_zh.md"><strong>简体中文</strong></a> •
    <a href="https://thedavidweng.github.io/sukiru/"><strong>Website</strong></a>
  </p>

  <br />
  <img src="public/screenshot.webp" alt="Sukiru main window" width="800" />
</div>

---

**Sukiru** checks and repairs the skill libraries of your coding agents. It
manages skills by orchestrating the two official installers, `npx skills` and
`gh skill`, and never keeps an install ledger of its own.

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

Website: <https://thedavidweng.github.io/sukiru/>

---

## ✨ Features

- 🩺 **Health report**: Problems are grouped into kinds you can act on: stale
  lock records, broken links, copies where links belong, diverging copies,
  skills with unknown sources, and ownership conflicts. Healthy layouts and
  standing notices fold into Notes.
- 🛠️ **One-click fixes**: Fix one problem or Fix All. Every fix becomes one
  batch that you confirm once, in plain language, with the exact commands one
  click away.
- ↩️ **Safe by construction**: Every batch runs as snapshot → execute → diff,
  with one-click rollback. The last 10 snapshots are kept.
- 📚 **Library**: See each skill's owner, provenance, pinned ref, and where it
  is placed across agents. Switch a skill between link and copy mode.
- 🔍 **Search and install**: Search skills.sh and `gh skill search`, preview
  `SKILL.md`, then install with the installer you choose, through the same
  confirm → snapshot → rollback pipeline.
- 🧭 **Adopt unknown skills**: Find candidate sources for hand-copied skills
  and bring them under an installer.
- 📴 **Works without the CLIs**: With neither Node.js nor `gh` installed,
  Sukiru is still a complete read-only health checker.
- 🍎 **Native**: Pure Swift, SwiftUI, and AppKit with system controls only, so
  it follows your appearance, accessibility settings, and Liquid Glass on
  macOS 26. Available in English and Simplified Chinese.

### Design principles

- **Zero ledger.** Sukiru never writes installer records. Ledger changes go
  through the official CLIs only. Sukiru performs file operations directly
  only for link management that no CLI offers (deleting a broken link,
  replacing a copy with a link, turning a link into a copy), always inside a
  snapshot.
- **Ownership routes repairs.** There is no global "backend" setting. A skill
  owned by `npx skills` is repaired with `npx skills`, and the same goes for
  `gh skill`.
- **No background activity.** No filesystem watchers, and nothing is
  downloaded or updated unless you ask. The app shows state at launch and
  when you click Refresh.
- **Deterministic.** The same disk state always produces the same report.
- **Malformed data is a reported problem, never a crash.**

---

## 🚀 Installation

### Requirements

- macOS 14 Sonoma or later on Apple silicon.
- Optional, to make changes:
  - [Node.js](https://nodejs.org/en/download) for `npx skills`.
  - [GitHub CLI](https://cli.github.com) 2.90.0 or later for `gh skill`.

Sukiru detects both tools at launch and disables only the actions that need a
missing tool. It finds them the way your terminal does, by reading your login
shell's PATH, so Node.js from Homebrew or a version manager (mise, fnm, nvm,
Volta, asdf, nodenv) works without extra setup. If you use a version manager
and Node.js is missing, Settings › Installers tells you to install it there
instead of offering Homebrew. The `skills` CLI needs no install: with Node.js
present, `npx` downloads it the first time you confirm a change that needs it,
and the confirmation says so beforehand. Sukiru never downloads or updates it
on its own; Settings › Installers also offers Download (to fetch it ahead of
time) and Update (when a newer release exists).

### Homebrew (Recommended)

```bash
brew install --cask thedavidweng/tap/sukiru
```

Upgrade:

```bash
brew upgrade --cask sukiru
```

The Homebrew cask removes the quarantine flag automatically, so Gatekeeper
does not block the first launch.

### Direct Download

1. Download `Sukiru.dmg` from [GitHub Releases](https://github.com/thedavidweng/sukiru/releases).
   Each release lists SHA-256 checksums in `checksums.txt`.
2. Drag **Sukiru.app** into `/Applications`.
3. Launch from Applications or Spotlight.

> [!NOTE]
> Releases use ad-hoc signing and are not notarized. If Gatekeeper blocks launch, open **System Settings › Privacy & Security** and click **Open Anyway** next to the Sukiru message (on macOS 14 you can also right-click **Sukiru.app** and select **Open**), or run:
> `xattr -cr /Applications/Sukiru.app`

---

## 📖 Getting Started

1. Launch Sukiru. It scans your user-level skill directories automatically.
2. To include project-level skills, add your project folders as project roots
   (**View › Add Project Root…**, `⇧ ⌘ A`, or in Settings).
3. Open **Health** to see problems and what caused them. Click a problem's
   fix button, or **Fix All**.
4. Review the confirmation sheet and confirm. To undo, use the result page or
   **Repair › Roll Back Selected Batch**.

---

## ⌨️ Keyboard Shortcuts

| Action | Shortcut |
| :--- | :--- |
| **Library / Health / Pending Changes / Snapshots / Search** | `⌘ 1` – `⌘ 5` |
| **Refresh** | `⌘ R` |
| **Add Project Root…** | `⇧ ⌘ A` |
| **Quick Look Selected Skill** | `⌘ Y` |
| **Show Findings for Selected Skill** | `⇧ ⌘ F` |
| **Reveal Selected Finding in Library** | `⇧ ⌘ L` |
| **Toggle Selected Finding Evidence** | `⇧ ⌘ E` |
| **Show Next / Previous Workspace** | `⌥ ⌘ →` / `⌥ ⌘ ←` |
| **Run Search** | `⌘ K` |
| **Install Selected Skill…** | `⇧ ⌘ I` |
| **Fix Selected Finding…** | `⌥ ⌘ F` |
| **Execute Batch** | `⌥ ⌘ E` |
| **Discard Batch** | `⌥ ⌘ X` |
| **Roll Back Selected Batch** | `⌥ ⌘ B` |
| **Settings** | `⌘ ,` |

All commands are also listed in the **View**, **Search**, and **Repair**
menus.

---

## 🛡️ Privacy & Permissions

Sukiru has no accounts, analytics, or telemetry. It reads local files and
runs the official CLIs on your machine. It connects to the network only to
look up the latest `skills` CLI version on the npm registry, when you
search (the skills.sh search API and `gh skill search`), preview a skill's
`SKILL.md` from GitHub, or run a CLI command that needs the network.
Snapshots and execution records stay in
`~/Library/Application Support/Sukiru`.

Details in [PRIVACY.md](PRIVACY.md).

---

## 💻 Command-Line Interface

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

---

## 🧱 Building from Source

### Prerequisites

- macOS 14.0+
- Xcode 26+ (Swift 6.2)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### Build & Run

```bash
git clone https://github.com/thedavidweng/sukiru.git
cd sukiru

swift test                 # core library and CLI tests
Scripts/build-app.sh       # generate the Xcode project and build Sukiru.app
Scripts/run-app.sh         # run the debug app
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full workflow, quality gates,
and test safety rules.

---

## 📄 Documentation & Contributing

- Website: <https://thedavidweng.github.io/sukiru/>
- Glossary of domain terms used in code and UI: [CONTEXT.md](CONTEXT.md)
- Architecture decision records: [docs/adr](docs/adr/README.md)
- Experiments on how the two official installers interact: [collision matrix](docs/collision-matrix.md)
- Contribution guidelines and quality gates: [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md)
- Bugs and feature requests: [GitHub Issues](https://github.com/thedavidweng/sukiru/issues)
- Security issues: follow [SECURITY.md](SECURITY.md). Do not open a public issue.

### Project history

Sukiru began as "Gino", a Rust/GPUI reimplementation of the `skills` CLI. In
September 2026 it was rebuilt as a native Swift app that delegates all
installer writes to the official tools ([ADR-0001](docs/adr/0001-pivot-to-zero-ledger-referee.md)).
The retired implementation is kept for reference on the
[`archive/rust-gui`](https://github.com/thedavidweng/sukiru/tree/archive/rust-gui)
branch.

---

## ⚖️ License

Copyright © 2026 David Weng. Licensed under the [Apache License 2.0](LICENSE).

Agent logos identify compatible tools and remain the property of their
owners. Their sources and licenses are listed in
[`App/Resources/AgentIcons-LICENSE.txt`](App/Resources/AgentIcons-LICENSE.txt).
