# 0005 — 词汇统一与旧资产处置

旧 `spec.md`（随 archive 分支留档）§4 Glossary 与新 `CONTEXT.md` 的冲突裁决（2026-09-14 拍板）：

- **Untracked Skill → Ownerless Skill（野技能）**：CONTEXT.md 词条已立，旧词退役。
- **Pending Change / Apply Batch**：名字保留（UI 沿用），语义改为**命令批次**——待执行的官方 CLI 命令序列及其预期效果，不再是文件操作计划。
- **agents.rs 116 宿主表**：作为数据被 Sukiru 读侧吸收；`protocol.rs` 的 13 个公开读侧条目为移植参考（写侧函数不移植）。
- **compatibility.toml 退役**：不再钉上游版本，latest + 能力探测（ADR-0002 / 0004）取代 pin 跑步机。
- **e2e 差分对拍**（`tests/e2e_cli_diff.rs`）：随 archive 留档作参考，不再维护。
- **碰撞矩阵实验**：授权立即执行（纯 CLI 受控混装，不写产品代码），产出落 `docs/collision-matrix.md`，校准 v1 检测规则。
