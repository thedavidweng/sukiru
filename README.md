> **⚠️ 路线已切换（2026-09-14）**：本仓库的 Rust/GPUI 全实现已退役，完整封存于 **`archive/rust-gui`** 分支。`main` 暂保留旧代码，稍后重置为新架构骨架。
>
> 产品转向 **Sukiru**（仓库稍后改名）：纯 Swift/SwiftUI 的 macOS 原生应用，**零账本**——所有写操作委托官方 CLI（`npx skills` / `gh skill`），读侧自建，核心能力是技能库的检测与修复。
>
> **Sukiru is the fast and tiny macOS native skill manager that manages your skills by orchestrating npx skills and gh skill.**
>
> 全部决策记录：`docs/adr/0001`–`0005` · 词汇表：`CONTEXT.md` · 官方 CLI 碰撞矩阵实验：`docs/collision-matrix.md`

# Gino

Gino is a native desktop manager for Vercel-compatible agent Skills. It shows
the Skills your coding agents actually see on disk, plans installs and
cleanups, and writes only after you review an Apply batch.

It is a GUI companion to [`npx skills`](https://github.com/vercel-labs/skills),
not a second installation protocol. Skills installed by Gino remain
understandable to the official CLI, and Skills changed by the CLI appear after
Refresh.

The shipped application is Rust-native. It does **not** require Node.js and
does not invoke `npx skills` during normal operation. The CLI remains the
protocol reference and the equivalent command shown in Skill detail.

Pinned upstream contract: `vercel-labs/skills@1.5.9` (`compatibility.toml`).

## Features

- Library over global, project, agent, and custom workspaces
- Marketplace search via [skills.sh](https://skills.sh)
- Pending Changes: install, update, move, remove, restore, duplicate cleanup
- One Apply = one snapshot + one Git backup commit
- Deterministic duplicate detection
- Tags, presets, activity, settings
- No product telemetry and no in-app self-update

Settings shows the installed version (`1.0.0`) and a link to
[GitHub Releases](https://github.com/thedavidweng/gino/releases). Gino does
not self-update.

## Install from source

Requires [Rust 1.85+](https://rustup.rs/) and Git. No Node.js.

```bash
git clone https://github.com/thedavidweng/gino.git
cd gino
cargo run --release
```

Run checks:

```bash
cargo test
cargo clippy --all-targets -- -D warnings
cargo fmt --check
```

Compare Gino's installer to the official CLI (needs network plus `npx` or `bunx`). CI runs this against `skills@latest` and installs `stale-docs-cleanup` from [thedavidweng/skills](https://github.com/thedavidweng/skills):

```bash
GINO_E2E=1 cargo test --test e2e_cli_diff -- --ignored --nocapture
```

Package a release:

```bash
./scripts/package.sh
```

On macOS this builds `dist/Gino.app` and a zip. If you have no Apple Developer
account, the script **ad-hoc signs** the app (no paid certificate) and
**skips notarization**. On another Mac, first launch is usually:
right-click → Open → Open.

Windows Authenticode and Linux distro packages need those operating systems
(or CI). This repository does not ship a Node.js runtime.

Prebuilt artifacts, when published, are on
[GitHub Releases](https://github.com/thedavidweng/gino/releases).

## Keyboard

- `1`–`9` switch Library through Backup
- `0` Activity
- `s` or `,` Settings
- `p` open Pending Changes
- `r` Refresh (read-only)
- `a` Apply the current batch
- `↑` / `↓` move the focused Skill
- `space` toggle the focused Skill
- `delete` / `backspace` queue removal of the selection
- `⌘A` / `Ctrl+A` select visible Skills
- `l` / `u` / `b` on Backup: keep local, use remote, or keep both
- `enter` submit Marketplace search or source
- `q` quit (prompts if Pending Changes exist)
- `?` shortcut list

## Compatibility

Gino reads and writes the same lockfiles as the pinned Vercel `skills` CLI.
Unknown lockfile JSON fields are preserved. The application never invents
lockfile fields or guesses a source from a Skill name.

Filesystem and Vercel lockfiles are the source of truth. SQLite stores only
UI and reconstructible metadata.

### What “compatible with `npx skills`” means

The official CLI is the rulebook. Gino reimplements those rules in Rust so
the app does not need Node.js. Two leftover compatibility notes:

1. **We have not yet run a side-by-side exam.** A “CLI differential harness”
   would install the same Skill with `npx skills@1.5.9` and with Gino, then
   compare folders and lockfiles. Until that exists, compatibility is
   implemented and unit-tested, not proven against the live CLI.

2. **Global lock hashes are a local stand-in.** The official global lock
   stores GitHub’s tree fingerprint (`skillFolderHash`). Offline, Gino stores
   a SHA-256 of the Skill files instead. Updates and duplicate detection
   still work. A lock written by Gino and one written by the CLI may
   disagree on that one hash field until we can ask GitHub for the real tree
   SHA. Unknown extra fields are still kept.

Windows and Linux are built in GitHub Actions CI. This checkout is a Mac, so
those two platforms were not compiled on the developer’s machine.

## License

MIT. See [LICENSE](LICENSE).
