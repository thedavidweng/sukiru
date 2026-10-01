> **⚠️ Route switched (2026-09-14) · 路线已切换**
>
> The former Rust/GPUI implementation is preserved in full on the **[`archive/rust-gui`](../../tree/archive/rust-gui)** branch. `main` is the Swift/SwiftUI rebuild (Sukiru v1): scan, Health UI, repair, and Search/Install are shipped.
>
> 旧的 Rust/GPUI 全实现完整封存于 **`archive/rust-gui`** 分支；`main` 为 Swift/SwiftUI 重建（Sukiru v1）：扫描、体检 UI、修复、搜索/安装已全部落地。

# Sukiru

Sukiru is a macOS native skill-library health checker and repairer. It
orchestrates `npx skills` and `gh skill`; it never writes installer ledger
state of its own ("零账本").

It reads the two official agent-skill installer ledgers (Vercel `skills`
lockfiles and GitHub `gh skill` frontmatter provenance) plus disk facts,
determines per-skill **Ownership**, and produces an explainable health report.
Repairs are executed **exclusively by the official CLIs**. Every write is a
user-reviewed Command Batch wrapped in snapshot → execute → post-diff →
one-click rollback.

## Design principles

- **Zero ledger** — Sukiru never writes installer ledger state. All
  skill-library writes go through the official CLIs.
- **No remote update checking** — that is the official CLIs' job.
- **No filesystem watchers** — the app shows launch state plus explicit Refresh.
- **Deterministic reads** — identical disk state produces identical reports.
- **Malformed data is a reported issue, never a crash.**

## Installation · 安装

**Homebrew (recommended · 推荐)**

```bash
brew install --cask thedavidweng/tap/sukiru
```

**Direct download · 直接下载**

Grab `Sukiru.dmg` from [GitHub Releases](https://github.com/thedavidweng/sukiru/releases),
drag **Sukiru.app** into `/Applications`, and launch.

从 [GitHub Releases](https://github.com/thedavidweng/sukiru/releases) 下载
`Sukiru.dmg`，将 **Sukiru.app** 拖入 `/Applications` 后启动。

## What works (v1)

Shipped:

- **Seam A scan engine** — ownership, drift, double-booked, ownerless, host
  inventory; `sukiru-cli scan` and `sukiru-cli capabilities`.
- **Health UI** — Library, Health, Settings (standard ⌘, window), window
  toolbar; Quick Look; Refresh; bilingual English + Simplified Chinese
  (`en` + `zh-Hans`). Native controls only, so macOS 26+ picks up Liquid
  Glass automatically.
- **Seam B repair** — CommandBatchBuilder, SnapshotStore, CLIExecutor,
  Differ/Rollback; Pending Changes and Snapshots surfaces.
- **Search / Install** — in-app search (skills.sh API + `gh skill search`),
  SKILL.md preview, installer choice (`npx skills` / `gh skill`), routed
  through the same Pending Changes → snapshot → post-diff → rollback
  pipeline as repairs.

Nothing else is planned for v1.

## Build, run, test

Requires macOS 14+ and Swift 6.2.

```bash
# Core library + CLI tests (~450)
swift test

# Real-CLI end-to-end (gated; skipped unless set)
SUKIRU_E2E=1 swift test
```

App (Xcode project generated from `project.yml`):

```bash
Scripts/build-app.sh
Scripts/run-app.sh
```

`Scripts/run-app.sh` execs the Mach-O binary so env overrides
(`SUKIRU_HOME`, `SUKIRU_ROOTS`, …) are inherited. Do not launch a freshly
built debug app with `open -F`.

After changing UI text, run `Scripts/sync-strings.sh` (after a build). It
syncs `App/Resources/Localizable.xcstrings` with the strings the compiler
extracted, the way Xcode does, and fails on stale or untranslated strings.
Pass `-AppleLanguages '(zh-Hans)'` to `Scripts/run-app.sh` to preview a
language; users pick one in Settings › General.

### Environment

- **`SUKIRU_HOME`** — replaces `$HOME` for all path resolution. Use it for
  sandboxed launches and tests. A set-but-missing path is fatal (`sukiru-cli`
  exits 2).
- **`SUKIRU_ROOTS`** — colon-separated extra project roots.
- **`SUKIRU_E2E=1`** — enables the real-CLI e2e suite. gh-networked cases
  also need `GH_TOKEN`.

Never run add / remove / update against the real `$HOME`. Point
`SUKIRU_HOME` at a fixture or throwaway sandbox.

CLI:

```bash
swift run sukiru-cli scan
swift run sukiru-cli capabilities
```

## Documentation

- Architecture decisions: [`docs/adr/0001`](docs/adr/0001-pivot-to-zero-ledger-referee.md)–[`0006`](docs/adr/0006-pure-swift-apple-native-feel.md)
- Glossary: [`CONTEXT.md`](CONTEXT.md)
- Official-CLI collision-matrix experiments: [`docs/collision-matrix.md`](docs/collision-matrix.md)

## Archived implementation

The retired Rust/GPUI application (the former "Gino") lives on the
[`archive/rust-gui`](../../tree/archive/rust-gui) branch, including its
`Cargo` project, `src/`, `tests/`, vendored `gpui-component`, and packaging
scripts. It is reference-only; the Sukiru rebuild does not resurrect it.

## License

Copyright © 2026 David Weng. Released under the Apache License 2.0. See
[LICENSE](LICENSE).
