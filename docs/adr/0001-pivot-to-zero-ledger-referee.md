# 0001 — 转向零账本"裁判"架构，Rust 全实现退役封存

Gino 原本是 vercel `skills` CLI 协议的完整 Rust+GPUI 复现（lockfile 读写 + CI 差分对拍）。但同类竞品已占住"通用 skills 管理器"心智（kitter：同栈 Rust+GPUI、两周 287 stars；aghub：webview 广度枢纽），而 `gh skill`（2026-04，GitHub CLI v2.90+）与 vercel CLI 形成了**两套官方安装器、两种溯源账本、写同一批 agent 目录**的格局。我们决定：停止全协议复现，转为纯 Swift（SwiftUI）macOS 原生应用——读侧自建（两本账 + 磁盘事实），写侧全部委托官方 CLI（`npx skills` / `gh skill`），自身不记第三本账（零账本），核心价值聚焦于混乱技能库的检测与修复。

## Considered Options

- **完整协议复现（原路线）**：弃。差异化真实（差分对拍证明的字节级 parity），但维护是无止境的跑步机（我们 pin 1.5.9 时上游已到 1.5.26），且"Rust+GPUI skills 管理器"的同栈心智已被 kitter 先占。
- **Swift UI + 保留 Rust 核心**：弃。桥接复杂度与"纯原生"标签冲突；写侧协议知识正是要甩掉的负担——gh 的入场让"裁判"位置比"另一个安装器"更值钱。
- **委托 + 零账本（选定）**：写侧维护成本归零（官方 CLI 是唯一写入者），信任故事从"parity 被我们证明"升级为"我们根本不写账本"；vercel 和 GitHub 谁都不会深读对方的账，中立裁判位置结构安全。

## Consequences

- 仓库**原地改造**（2026-09-14 grilling session 拍板）：当前 tip 封存至 `archive/rust-gui` 分支作为参考图纸（锁 schema、宿主表、检测规则），`main` 转为 Swift 应用，新 main 的 README 置顶横幅解释路线切换。旧 GPUI 版不发布。
- e2e 差分对拍资产随存档保留，不再作为卖点。
- vercel 侧写操作依赖用户机器上的 Node 运行时；叙事定为"零捆绑 runtime，编排机器上已有的工具"。`gh skill` 为 public preview：松耦合（调用而非复刻）、锁最低版本 2.90.0、启动时能力探测。
- 读侧协议知识（两种 lockfile、`metadata.github-*` 溯源、宿主目录表）仍自建——它就是产品本体；红线是**写侧协议知识一行都不再建**。
- 只做 macOS。
