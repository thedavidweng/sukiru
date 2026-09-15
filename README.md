> **⚠️ Route switched (2026-09-14) · 路线已切换**
>
> The former Rust/GPUI implementation has been **retired** and is preserved in full on the **[`archive/rust-gui`](../../tree/archive/rust-gui)** branch. `main` has been reset to the new Sukiru architecture skeleton.
>
> 旧的 Rust/GPUI 全实现已退役，完整封存于 **`archive/rust-gui`** 分支；`main` 已重置为新的 Sukiru 架构骨架。

# Sukiru

**Sukiru is the fast and tiny macOS native skill manager that manages your skills by orchestrating npx skills and gh skill.**

Sukiru reads the two official agent-skill installer ledgers (Vercel `skills`
lockfiles and GitHub `gh skill` frontmatter provenance) plus disk facts,
determines per-skill **Ownership**, and produces an explainable health report.
Repairs and installs are executed **exclusively by the official CLIs**
(`npx skills`, `gh skill`); Sukiru persists zero ledger state of its own
("零账本"). Every write is a user-reviewed Command Batch wrapped in
snapshot → execute → post-diff → one-click rollback.

## Design principles

- **Zero ledger** — Sukiru never writes installer ledger state. All
  skill-library writes go through the official CLIs.
- **No remote update checking** — that is the official CLIs' job.
- **No filesystem watchers** — the app shows launch state plus explicit Refresh.
- **Deterministic reads** — identical disk state produces identical reports.
- **Malformed data is a reported issue, never a crash.**

## Documentation

- Architecture decisions: [`docs/adr/0001`](docs/adr/0001-pivot-to-zero-ledger-referee.md)–[`0005`](docs/adr/0005-glossary-and-legacy-disposition.md)
- Glossary: [`CONTEXT.md`](CONTEXT.md)
- Official-CLI collision-matrix experiments: [`docs/collision-matrix.md`](docs/collision-matrix.md)

## Archived implementation

The retired Rust/GPUI application (the former "Gino") lives on the
[`archive/rust-gui`](../../tree/archive/rust-gui) branch, including its
`Cargo` project, `src/`, `tests/`, vendored `gpui-component`, and packaging
scripts. It is reference-only; the Sukiru rebuild does not resurrect it.

## License

MIT. See [LICENSE](LICENSE).
