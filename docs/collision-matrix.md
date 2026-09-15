# 碰撞矩阵实验记录

2026-09-14，受控沙箱（`/tmp/sukiru-cm`，npx 侧 HOME 隔离，gh 侧仅写沙箱项目目录），测试技能 `stale-docs-cleanup`（源 `thedavidweng/skills`）。环境：`gh 2.100.0`、`npx skills@latest`（Node v24.20.0）。本记录为事实证据，供 ADR-0004 的检测规则校准。

## 矩阵与结果

| # | 场景 | 实测结果 | 裁判启示 |
|---|---|---|---|
| 0 | 发现规则对比 | npx 深度遍历在 `maintenance/` 前缀下找到 22 个技能；gh 约定路径扫描找到 0，报 "curated list"，必须用精确路径 + `SKILL.md` 后缀才能装 | **同一源仓库，两个安装器的可见性不同**；溯源缺失 ≠ 野技能，可能只是 gh 装不上 |
| 1 | npx 基线（`add -y`，claude-code） | 非交互默认 **copy 模式**：`.agents/skills` canonical + `.claude/skills` 副本；锁（v1）记录 `source/sourceType/skillPath/computedHash`；frontmatter 保持上游原样 | vercel 的账完全在锁里 ✓ |
| 2 | gh 基线（exact-path install） | 只写宿主目录；注入 `metadata.github-{path,ref,repo,tree-sha}`；装@main 时 `github-ref: refs/heads/main`（分支名），内容身份靠 tree-sha；无锁 | gh 的账随身走 ✓ |
| 3 | npx 先装 → gh `--force` 双记账 | gh 覆盖 `.claude` 副本并注入溯源；vercel 锁 `computedHash` 原样（**已过期**）；`.agents` canonical 未动 → **宿主副本与 canonical 分歧**；双方零警告 | 双记账 + 锁漂移 + 副本分歧三症并发且全静默 |
| 4 | npx `update -y -p` 覆盖双记账态 | 报 "Updated ✓"，但锁 hash 不变、`.claude` 里 gh 溯源**原样幸存**、canonical 未动 | npx update 不校验也不重写已漂移的宿主副本；上游未变时 gh 账幸存（上游变化时行为未测） |
| 5 | gh 先装 → npx `add -y` 反向双记账 | npx 覆盖 `.claude` 副本，**gh 溯源被静默抹掉**（grep=0），同时写入 vercel 锁；canonical 未建（与场景 1 差异待查） | 方向不对称：gh `--force` 保住自己的账，npx `add` 直接摧毁对方的 |
| 6 | npx `remove -y` 对 gh 独有技能（无锁） | **直接删除**："Successfully removed 1 skill(s)"，`.claude/skills` 清空 | npx remove 是**按名字的发现级删除**，不管锁、不管归属——会误删 gh 账甚至野技能 |
| 7 | gh `update --all` 对 npx 独有技能 | 逐个 "no GitHub metadata" 跳过提示，不写盘，exit 0；顺带证实用户真实主目录全部技能均无 gh 溯源 | gh 尊重账本边界 ✓；本机语料是纯 vercel 世界 |
| 8 | 混装项目的归属视图 | gh list：1 owned（`.claude`，sourceURL=repo）+ 1 ownerless（canonical，sourceURL=""）；npx list：1 条（canonical，"Agents: Codex, Claude Code"）；磁盘真相：1 个名字 3 份副本、两本账各说各话 | **归属判定必须三源对齐**（两本账 + 磁盘发现）；`gh skill list --json` 可作读侧辅助（sourceURL 空 = gh 眼中的野） |

## 对 v1 检测规则的修正（已并入 ADR-0004）

1. **新增规则：canonical / 宿主副本分歧**（copy 模式下被 gh `--force` 只改宿主副本造成）。
2. **新增安全规则：危险删除警示**——派发 `npx skills remove` 前必须警示其按名字删除、可能跨归属（场景 6 实锤）。
3. 双重记账的检测形态 = 同名技能同时有 vercel 锁条目 + gh frontmatter 溯源（场景 3/5 两个方向）。
4. **未测变体**（后续实验）：symlink 模式下的碰撞（非交互默认是 copy）；上游确有变化时 npx update 是否抹掉 gh 溯源。

## 证据样本

场景 3 后 `.claude/skills/stale-docs-cleanup/SKILL.md` frontmatter：

```yaml
metadata:
  github-path: maintenance/stale-docs-cleanup
  github-ref: refs/heads/main
  github-repo: https://github.com/thedavidweng/skills
  github-tree-sha: 214349b9b6ede59ff72ba15797186668fcfec535
```

同项目 vercel 锁（未更新）：

```json
"stale-docs-cleanup": {
  "source": "thedavidweng/skills",
  "sourceType": "github",
  "skillPath": "maintenance/stale-docs-cleanup/SKILL.md",
  "computedHash": "8844f550…"
}
```
