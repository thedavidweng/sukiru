# 0007 — Health 以"问题"为单位呈现，一键修复，批次级单次确认

旧 Health 按检测规则（rule ID）罗列发现，用户看不出"出了什么事、该怎么办"；每个修复都要进 Pending Changes 逐条命令标记已审查，Fix All 根本不存在。真实机器扫描给出 466 条发现，其中 153 条是健康布局（共享目录的别名链接）、100 条是常驻提示，真正的问题被淹没。参考 `npx skills`（共享目录 + 链接默认、单宿主自动拷贝）、cc-switch 与 magpie（共享仓 + 链接、拷贝兜底、操作前备份），我们决定：

- **问题目录（`ProblemKind`）**：规则 → 用户语言的问题种类（锁记录已失效、失效链接、副本代替链接、副本内容不一致、来源未知、所有者冲突、新版锁文件、备注）。健康布局与常驻提示归入"备注"，默认折叠，不计入问题数。每种问题带说明文案与默认一键修复。
- **一键修复与 Fix All**：`CommandBatchBuilder.buildApplicable` 宽松构建——能修的进一个批次，需要用户选择的列为"未包含"而不阻塞其余。
- **批次级单次确认取代逐条审查**：一个批次弹一次确认表，用白话汇总变更、命令一键可展开；快照 + 一键回滚不变，确认后结果页直接提供撤销。逐条审查的安全收益被快照/回滚覆盖，而其成本让修复上百条失效记录变得不可用。
- **直接文件操作的边界扩到"链接管理"**：账本写入仍只经官方 CLI（ADR-0001 红线不变）；没有 CLI 能做的磁盘布局操作——删除失效链接（`delete-link`）、副本换成指向共享副本的链接（`relink`）、链接实体化为副本（`materialize`）——走 `sukiru-fileop`，带危险标记、快照保护、路径越界预检。
- **失效锁记录走 `npx skills remove <name> -g -y`**：实测它同时清理锁记录与残留链接；无锁的失效链接 npx 无法处理，才用 `delete-link`。
- **宿主自管技能（`Ownership.agent`）**：Hermes（`.bundled_manifest` / `.hub/lock.json`）与 Codex（`.system/`）目录里的技能由宿主自己的记录管理，标为"智能体管理"，排除在重复/冒名/分歧问题之外，只展示不修复。
- **链接 ↔ 副本切换**：Library 按技能切换（`buildModeSwitch`）；Health 的"副本代替链接"一键改回链接；Settings 提供"以副本形式安装新技能"（`npx skills add --copy`）。
- **来源未知的技能**：按名称查 skills.sh 给出候选来源，用户也可填任意 `owner/repo` 或 URL，经 `npx skills add <source> --skill <name> -a <宿主…>` 收编进 Vercel 账本；或直接删除。

## Considered Options

- **保留逐条审查，只加 Fix All**：弃。111 条失效锁记录意味着 111 次点击，等于没有 Fix All。
- **Sukiru 自己改写锁文件清理失效记录**：弃。违反零账本红线；`npx skills remove` 已能做到。
- **副本 → 链接也交给 `npx skills add` 重装**：弃。需要网络与来源，且对来源未知或宿主自管的副本无效；本地 relink 可快照回滚。

## Consequences

- Pending Changes 只剩修复决策面板与执行结果；每条命令的检查移进确认表的命令展开区。
- `relink` 会替换内容不同的副本（危险标记 `discardsLocalChanges`），确认表单列一行"本地修改将被丢弃"。
- 宿主自管目录被视为只读事实；若宿主改变其记录格式，检测需跟进。
