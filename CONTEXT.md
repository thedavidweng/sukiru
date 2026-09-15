# Sukiru

原名 Gino（见 ADR-0003）。一个 macOS 原生应用：读两本官方账本与磁盘事实，检测并修复混乱的 agent 技能库；所有写操作委托官方 CLI，自身零账本。（决策见 docs/adr/。）

## Language

**Agent Skill（技能）**:
一个包含 `SKILL.md` 的目录，agentskills.io 规范定义的可移植指令单元；宿主凭 frontmatter 激活它。
_Avoid_: 插件、能力

**Agent Host（宿主）**:
消费技能目录的编码 agent（Claude Code、Codex、Cursor…）。宿主是即插即用的：只认目录里的文件，不关心谁装的。
_Avoid_: 平台、客户端

**Ledger（账本）**:
安装器私有的安装记录（装了什么、来自哪、什么版本、装给谁），是更新/钉版/卸载的依据。账本是给安装器看的，不是给宿主看的。
_Avoid_: 元数据、记录

**Vercel 账本**:
vercel CLI（`npx skills`）的账本，记在独立 lockfile（项目 `skills-lock.json`；全局 v3 锁 `~/.agents/.skill-lock.json`）。技能文件保持上游原样，账在旁边。

**GitHub 账本**:
`gh skill` 的账本，安装时直接写进 `SKILL.md` frontmatter 的 `metadata.github-*`（repo、path、ref、pinned、tree-sha）。账随身走。

**Provenance（溯源）**:
账本条目里标识来源的部分：仓库、ref、内容 hash。
_Avoid_: 来源信息

**Ownerless Skill（野技能）**:
两本账都没有记录的技能（手拷、脚本放置的）。宿主照常可用，但任何安装器都无法更新或干净卸载；修复的主要对象。
_Avoid_: 未安装、Untracked Skill（旧 spec 用词，已退役）

**Drift（漂移）**:
磁盘事实与账本记录脱节的状态（例：gh 更新后 vercel 锁里的内容 hash 过期，反之亦然）。
_Avoid_: 不一致

**Ownership（归属）**:
哪个账本认领了某个技能的事实，由账本记录判定，不由用户偏好决定；修复与更新按归属派发给对应的官方 CLI。
_Avoid_: 后端选择、全局后端

**Adoption（收编）**:
把野技能纳入某本账本、使其变为可管理的操作（例：`gh skill update` 交互模式询问来源并注入溯源）。收编需选择账本，因此是用户决策点。
_Avoid_: 导入

**Double-booked（双重记账）**:
两本账本同时认领同一技能的状态；修复必须由用户裁决保留哪本，没有客观正确答案。

**Command Batch（命令批次）**:
待执行官方 CLI 命令的序列及其预期效果；执行前须审查，伴随快照，可回滚。UI 沿用 "Pending Changes" 叫法。
_Avoid_: 文件操作计划（已退役的旧语义）
