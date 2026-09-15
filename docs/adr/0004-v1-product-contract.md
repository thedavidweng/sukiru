# 0004 — v1 产品契约：全量本地读侧 + 命令批次安全模型 + 体检先行

零账本红线（ADR-0001）的具体形状（2026-09-14 grilling 批量拍板）：

- **读侧全量自建**：两本账 schema（vercel `skills-lock.json` v1 / 全局 v3 锁 `~/.agents/.skill-lock.json`、gh `metadata.github-*`）、`SKILL.md` frontmatter 解析、116 宿主目录表（`agents.rs` 数据吸收）。**不做**远端更新检查（那是 `gh skill update --dry-run` / `npx skills update` 的职责，不造第二个 update）；**不建**写侧 diff 预测 planner（红线：写侧协议知识一行不建）。
- **安全模型**：每个命令批次强制快照 → 执行 → 事后 diff → 一键回滚（沿用旧 spec §12 设计）。野技能的文件操作允许直接执行（无账可碰，受快照保护）。
- **依赖**：锁 gh ≥ 2.90.0；vercel 侧探测 `npx skills` 可解析性、版本数字为辅；零捆绑（不自动安装任何 runtime，缺件按 ADR-0002 降级）。
- **v1 检测规则**：跨宿主重复、symlink 真伪与断链、vercel 锁漂移（重算 computedHash 对账）、gh 溯源存在性 + pin 展示、有锁无文件、有文件无锁、双重记账。kitter / aghub 遗留识别推迟到 v2。
- **MVP 里程碑**：只读体检版先发布（零写入风险、尽早验证需求），修复编排随后，新安装最后。

## Consequences

- 修复正确性依赖读侧归属判定；碰撞矩阵实验（受控 CLI 混装，产出见 `docs/collision-matrix.md`）校准检测规则的真实行为假设。
- "写入前审查"的形态 = 命令预览 + 事后 diff + 回滚，而非文件级预测 diff。

## 实验校准（2026-09-14 碰撞矩阵，见 docs/collision-matrix.md）

在上述清单基础上追加两条（由受控实验实锤）：

- **canonical / 宿主副本分歧**：copy 模式下 gh `--force` 只改宿主副本、不动 `.agents/skills` canonical，造成双副本漂移且双方零警告。
- **危险删除警示**：`npx skills remove` 是按名字的发现级删除，会跨归属删除（实测删掉 gh 独有技能）。派发该命令前必须警示与快照保护。

另有事实修正：双记账的检测形态 = 同名技能同时具有 vercel 锁条目 + gh frontmatter 溯源；非交互 `npx add -y` 默认 copy 模式；同一源仓库两个安装器发现规则不同（维护性前缀仓库 gh 发现失败）。
